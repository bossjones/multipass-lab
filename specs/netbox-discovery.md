# Plan: NetBox Discovery for `centralized_netbox` (Diode + orb-agent)

> Filename note: the request said `specs/netdata-discovery.md`, but every linked resource is
> **NetBox** Discovery (NetBox Labs' Diode ingestion server + the `orb-agent` discovery agent),
> not [Netdata](https://www.netdata.cloud/) the monitoring tool. This plan is filed as
> `specs/netbox-discovery.md` to match the repo's `netbox-*` / `cli-netbox` naming. If you truly
> meant Netdata, stop here — this is the wrong plan.

Task type: **feature** · Complexity: **complex**

## Task Description

Add **network discovery** to the `centralized_netbox` cluster so that, instead of every VM
hand-registering itself (today's `netbox-register.sh` self-registration), a discovery agent
**scans the Multipass subnet and populates NetBox automatically** via NetBox Labs' Diode pipeline.

Concretely, wire up the three-part NetBox Labs discovery stack against the lab's self-hosted
NetBox:

1. **[Diode server](https://netboxlabs.com/docs/diode/)** — a self-hosted ingestion pipeline
   (nginx ingress + ingester + reconciler + auth + Ory Hydra + Redis + Postgres) that accepts
   gRPC-ingested data and reconciles it into NetBox.
2. **[diode-netbox-plugin](https://github.com/netboxlabs/diode-netbox-plugin)** — a NetBox plugin
   (`netbox_diode_plugin`) that exposes the `/api/plugins/diode` surface the reconciler writes to.
3. **[orb-agent](https://github.com/netboxlabs/orb-agent)** — the discovery agent
   (`netboxlabs/orb-agent`) that runs `network_discovery` (nmap) over the Multipass `/24` and
   ingests discovered IPs/hosts into Diode over gRPC.

The feature is delivered as an **opt-in flag** (`enable_discovery`, default **off**), exactly like
`centralized_logging`'s `enable_coroot`: with the flag off the cluster is byte-for-byte what it is
today; with it on the cluster reconfigures to a Diode-compatible footprint.

## Objective

When complete:

- `just check centralized_netbox` (hermetic, no VMs) still passes with `enable_discovery=false`
  **and** asserts the rendered discovery wiring when `enable_discovery=true`.
- `tofu -chdir=clusters/centralized_netbox apply -var enable_discovery=true` (or the tfvars flip +
  `just recreate centralized_netbox`) brings up a NetBox that has the Diode plugin installed, a
  running Diode server stack, and an `orb-agent` VM that scans the subnet.
- After a discovery run, **NetBox contains IP Addresses / objects the agent discovered** (not just
  the two hand-registered VMs), verifiable over the REST API.
- `just verify centralized_netbox` (testinfra) and `just netbox-check centralized_netbox` assert the
  discovery path end to end, and skip those assertions cleanly when discovery is off.
- With `enable_discovery=false`, **nothing changes** — NetBox 4.1, pinned token, self-registration,
  and every existing test remain green.

## Problem Statement

`centralized_netbox` today proves *push* registration: each VM POSTs itself into NetBox with a
**pinned lab API token**. That works because the cluster deliberately **pins NetBox 4.1**
(`netbox_docker_ref = 3.0.2`), which uses **v1 plaintext tokens** (`Authorization: Token <40hex>`)
whose value can be fixed for deterministic tests (see `specs/centralized_netbox.md` and
`variables.tf`).

Discovery is the *pull* model — the missing half of a real "source of truth". But standing it up
collides head-on with that version pin:

> **The Diode ecosystem does not support NetBox 4.1 in any usable way.** The community setup
> prerequisite is **NetBox ≥ 4.2.3**. The plugin-compatibility table lists a `0.4.0` build for
> NetBox 4.1.0, but the current Diode **server requires plugin 1.1.0** (the OAuth2/Hydra auth
> architecture, the `/api/plugins/diode` reconciler API, and `*_client_secret` config all target
> plugin 1.x + NetBox 4.2.3). There is no supported path to run today's Diode server against 4.1.

So the feature forces the one thing the current cluster was built to avoid: **moving off NetBox
4.1**. The good news (see the next section) is that moving off 4.1 does **not** cost us the pinned
token — the pin cliff is 4.5, not 4.2. Two real problems still ride along:

- **Plugin install needs a custom image.** netbox-docker installs plugins by *building* an image
  (`plugin_requirements.txt` + a `Dockerfile-Plugins` + `PLUGINS`/`PLUGINS_CONFIG`), not by pulling
  the published one. `specs/centralized_netbox.md` §"Future work" already flags this as deferred.
- **Runtime-generated OAuth2 secrets break the render-time model.** Diode's `quickstart.sh`
  generates three OAuth2 client secrets at runtime, but this repo bakes everything (server IP,
  token) into cloud-init at **`tofu` render time**. The agent VM can't learn a runtime-generated
  secret. We need deterministic, pinned OAuth2 credentials — the same pattern as the pinned API
  token.

## NetBox token model across versions — the pin, corrected

The `netbox_docker_ref` variable comment (and the original framing of this plan) says *"NetBox 4.2+
switched to hashed v2 (Bearer) tokens where a known token value cannot be set."* **That version is
wrong** — verified against the NetBox 4.5 release notes and the netbox-docker issue tracker
(July 2026):

| NetBox | Token model | Header | Known/pinned key? | Diode (≥ 4.2.3)? |
|---|---|---|:--:|:--:|
| 4.1 (current pin) | v1 plaintext | `Authorization: Token <40hex>` | ✅ settable | ❌ too old |
| **4.2.3 – 4.4.x** | v1 plaintext | `Authorization: Token <40hex>` | ✅ **settable** | ✅ **yes** |
| 4.5.x | **v2** default (HMAC + pepper); v1 still accepted | `Authorization: Bearer nbt_<KEY>.<TOKEN>` (v2) / `Token …` (v1) | ⚠️ v1 still pinnable via ORM; netbox-docker's helper now mints **random-key v2** | ✅ yes |
| 4.7+ | v2 only (v1 **removed**) | `Bearer nbt_<KEY>.<TOKEN>` | ❌ no fixed plaintext without extra work | ✅ yes |

Key facts (sourced):

- Hashed **v2** tokens were introduced in **NetBox 4.5.0 (2026-01-06)**, *not* 4.2. In 4.5,
  *"backward compatibility with legacy (v1) tokens is retained"*, but *"support for legacy tokens
  will be removed in NetBox v4.7."*
- **v4.4.2** removed the ability to *retrieve* a v1 token's plaintext via the API — but that is
  retrieval, **not** creation. Creating a token with an explicit `key=` via `manage.py` (exactly
  what `netbox-stack.sh` does today with `Token.objects.get_or_create(key=…)`) still yields a
  usable, known-value v1 token on 4.2–4.4.x.
- On **4.5**, netbox-docker's `SUPERUSER_API_TOKEN` helper now creates a **v2** token and lets
  NetBox generate a random key (netbox-docker issues [#1589], [#1647]) — so deterministic pinning
  breaks *through that path*. This repo doesn't use that path (it uses `manage.py`), and a v1 token
  can still be created explicitly on 4.5, but the default helper is no longer deterministic.

**Consequence — "later release" is not only possible, it's cheap.** Because Diode needs ≥ 4.2.3 and
pinnable v1 tokens survive through **4.4.x**, the discovery path can pin **NetBox 4.4.x** and keep
the *entire* existing auth contract untouched: `netbox-stack.sh`'s `manage.py` token creation, the
client's baked `Authorization: Token`, `netbox_cli`, and the testinfra suite all keep working with
**zero** auth rework. The dreaded "rework auth" scenario only begins at **4.5**, and is only
*forced* at **4.7**.

**Fix the source of the myth too.** The `variables.tf` comment for `netbox_docker_ref` should be
corrected from "4.2+" to "**4.5+**" so the next reader doesn't inherit the wrong cliff. (Small,
separate edit — see [Notes](#notes).)

### If you *do* want to ride 4.5+ (forward-compat, not needed for discovery)

Only relevant if you want the discovery cluster on the newest NetBox rather than the recommended
4.4.x. Options, worst-case first:

1. **4.5 / 4.6, keep a v1 token (stopgap).** v1 is still accepted through 4.6. Bypass
   netbox-docker's v2-defaulting helper (already done) and explicitly create a v1 token via
   `manage.py`. Verify in a spike that the 4.5 `Token` model still lets ORM set a fixed v1 key.
   Deadline: v1 is **gone in 4.7**.
2. **v2 with runtime read-back.** Create the token, read the one-time plaintext NetBox prints at
   creation, write it to `/var/lib/netbox-bootstrap/api-token`. Host-side consumers (`netbox_cli`,
   testinfra) fetch it over SSH instead of from `tofu output`. **Cost:** the client VM can't bake
   an unknown-at-render-time token — self-registration would need to fetch the token at runtime too
   (e.g. scp from the server, or the server writes discovered facts and the client stops
   self-registering once discovery covers it). This is the real reason to prefer 4.4.x.
3. **Deterministic v2 (future).** A `SUPERUSER_API_KEY`-style knob to pin the v2 key is an open
   upstream request ([#1647]); until it lands, v2 keys are server-generated. Track it; don't build
   on it yet.

[#1589]: https://github.com/netbox-community/netbox-docker/issues/1589
[#1647]: https://github.com/netbox-community/netbox-docker/issues/1647

## Key Architectural Decision — resolving the NetBox version conflict

This is the one decision that governs everything else; the plan commits to **Option A** and
documents the alternatives so the choice is legible.

| | A — Opt-in flag bumps version (recommended) | B — Bump the whole cluster to 4.2.3+ | C — New `centralized_discovery` cluster |
|---|---|---|---|
| Default cluster | **Unchanged** (4.1, pinned token, self-registration) | Changes for everyone | Unchanged |
| Blast radius | Low — all new behaviour is behind `enable_discovery` | High — reworks the headline self-registration path | Low, but duplicates the whole cluster |
| Matches repo pattern | Yes — mirrors `enable_coroot` | No | Partly, but user asked to *update* `centralized_netbox` |
| Two NetBox versions to reason about | Yes (a real cost) | No | No |

**Recommendation: Option A, pinned to NetBox 4.4.x.** `enable_discovery` (default off) gates a
version bump + the entire Diode footprint. Off = today's cluster, every existing test green. On =
NetBox bumped to **4.4.x** (a netbox-docker `3.4.x` release, e.g. image `v4.4-3.4.1`; the highest
band that keeps **pinnable v1 tokens** *and* satisfies Diode's ≥ 4.2.3 — with plugin **1.7.0** per
the compat table), plus the custom plugin image, Diode server, and orb-agent VM. This keeps the
cluster's proven self-registration demo intact and isolates the heavier, less-deterministic
discovery stack behind a flag, exactly as Coroot is isolated in `centralized_logging`.

**The token sub-decision is resolved, not risky.** Per
[NetBox token model across versions](#netbox-token-model-across-versions--the-pin-corrected), a
**known-value** token stays settable through **4.4.x** — the hashed-v2 cliff is **4.5**, not 4.2.
So bumping to 4.4.x for discovery requires **zero** token-handling changes: `netbox-stack.sh`'s
`manage.py` token creation, the client's baked `Authorization: Token`, `netbox_cli`, and testinfra
all keep the pinned token. Phase 0 keeps a *confirmation* spike (create a known-key token on the
exact 4.4.x image, assert it authenticates) purely as a guardrail, but it is expected to pass by
design — it is no longer a blocking fork. Discovery's own credentials are **separate** OAuth2
secrets (below), independent of the NetBox token entirely.

Everything downstream is mechanical.

## Solution Approach

Follow the established cluster shape (`main.tf` → `local.flags`/thread-through → `templatefile`
cloud-init → hermetic + live tests), adding a discovery dimension gated on one boolean.

**1. Deterministic OAuth2 credentials (the key to keeping the lab hermetic).** Do **not** run
`quickstart.sh` (which randomises secrets). Instead render Diode's `.env`,
`oauth2/client/client-credentials.json`, `docker-compose.yaml`, and `nginx/nginx.conf` from
templates using **pinned lab secrets** injected as `tofu` variables — the same
"deliberately-non-secret, exposed via `tofu output`, do-not-copy-to-Proxmox" philosophy as
`netbox_api_token`. The three clients and where each secret lands:

| OAuth2 client | scope | Consumed by | Rendered into |
|---|---|---|---|
| `diode-ingest` | `diode:ingest` | **orb-agent** (`DIODE_CLIENT_ID`/`DIODE_CLIENT_SECRET`) | agent VM `agent.yaml` + env |
| `diode-to-netbox` | `netbox:read netbox:write` | **diode-reconciler** | Diode `.env` |
| `netbox-to-diode` | `diode:read diode:write` | **NetBox plugin** (`netbox_to_diode_client_secret`) | NetBox `PLUGINS_CONFIG` |

Because the `netbox-to-diode` secret is a pinned var, it's known at render time → bake it straight
into `PLUGINS_CONFIG`; no runtime extraction, no chicken-and-egg. The agent VM is likewise rendered
with the pinned `diode-ingest` secret, so it needs no runtime handshake with the server.

**2. Server VM (when `enable_discovery=true`).** Extend `netbox-stack.sh`:
   - Bump the NetBox image to **4.4.x** (`netbox_docker_ref_discovery`, e.g. a `3.4.x` netbox-docker
     release / `v4.4-3.4.1`) — keeps the pinned v1 token, satisfies Diode (plugin 1.7.0).
   - Build a **custom NetBox image**: add `netboxlabs-diode-netbox-plugin` to netbox-docker's
     `plugin_requirements.txt`, add the stock `Dockerfile-Plugins`, set
     `PLUGINS = ["netbox_diode_plugin"]` + `PLUGINS_CONFIG` (with `diode_target_override:
     grpc://<server>:8080/diode`, `diode_username: diode`, pinned `netbox_to_diode_client_secret`)
     via a mounted `configuration/` extra, and `docker compose build` before `up -d`.
   - Run `manage.py migrate netbox_diode_plugin` (idempotent; folds into the existing retry loop).
   - Bring up the **Diode server stack** as a *separate* compose project under `/opt/diode`
     (rendered files, pinned secrets), `docker compose up -d`. `diode-auth-bootstrap` registers the
     pinned clients into Hydra. `NETBOX_HOST=http://<server>:8000`.
   - Keep the existing cluster/site/seed bootstrap. Write a new
     `/var/lib/netbox-bootstrap/discovery-done` marker after Diode is healthy.

**3. Agent VM (`multipass_instance.agent`, `count = enable_discovery ? 1 : 0`).** A third,
small VM `centralized-netbox-agent`. cloud-init installs docker, renders `/opt/orb/agent.yaml`
(network_discovery policy scoped to the live `/24`, `target: grpc://<server>:8080/diode`, pinned
ingest creds), and runs `netboxlabs/orb-agent` as a `--net=host` container via a systemd oneshot
(`orb-agent.service`). A `discovery-done` marker is written after the first run. `device_discovery`
(NAPALM) is **out of scope** for the headline (its drivers target network OSes, not Ubuntu VMs) —
noted as future work.

**4. Sizing.** With discovery on, the server runs netbox-docker (~6 containers) **plus** the Diode
stack (~9 containers incl. a second Postgres + Redis + Hydra). Auto-bump the server the way Coroot
auto-bumps the k0s node (`local.server_size` in `main.tf`): **6 vCPU / 10G / 50G**. Agent VM stays
tiny (1 vCPU / 1G / 10G). Default (discovery-off) sizing is untouched.

**5. Verification.** Extend `netbox_cli.py` with a `discovery` introspection command and fold
discovery assertions into `check` (gated on the flag / on `/api/plugins/diode/` being present).
Add testinfra assertions for the Diode stack + a discovered-objects E2E. Add a
`just netbox-discover` recipe to trigger an on-demand scan.

**6. Applying it.** Because all of this is cloud-init, enabling the flag requires
**`just recreate centralized_netbox`**, not `just up` (same rule as Coroot / any `.tftpl` edit).

### Architecture (discovery enabled)

```
 ┌───────────────────────────────┐   network_discovery (nmap) over the Multipass /24
 │ centralized-netbox-agent      │   orb-agent (netboxlabs/orb-agent, --net=host)
 │  /opt/orb/agent.yaml          │ ── gRPC ingest ──▶ grpc://<server>:8080/diode
 └───────────────────────────────┘   auth: diode-ingest OAuth2 client (pinned)
                                              │
 ┌────────────────────────────────────────────▼──────────────────────────────┐
 │ centralized-netbox-server                                                  │
 │  netbox-docker (custom image: netbox_diode_plugin)   :8000  /api/plugins/diode │
 │  diode server stack  :8080 (nginx gRPC+HTTP)  :9090 /metrics               │
 │    nginx · ingester · reconciler · auth · hydra · redis · postgres         │
 │  reconciler ──(diode-to-netbox OAuth2)──▶ NetBox /api/plugins/diode        │
 └────────────────────────────────────────────────────────────────────────────┘
        discovered IPs/hosts land in NetBox IPAM/DCIM  (verified over REST)
```

## Relevant Files

Use these files to complete the task:

- `clusters/centralized_netbox/variables.tf` — add `enable_discovery` + pinned discovery secret
  vars + `diode_docker_ref`/`orb_agent_image`/`netbox_docker_ref_discovery` (Diode-compatible
  NetBox pin). Follow the existing validation-block style.
- `clusters/centralized_netbox/terraform.tfvars` — document the new flag (kept **off**).
- `clusters/centralized_netbox/main.tf` — add `local.flags`/thread-through for discovery, the
  server-size auto-bump, the conditional `agent` instance (`count`), and the extra `templatefile`
  renders + `local_file`s for the Diode config + agent config.
- `clusters/centralized_netbox/cloud-init/server.yaml.tftpl` — gate the plugin build + Diode
  bring-up behind `%{ if enable_discovery }` blocks in `write_files`/`runcmd`; new marker.
- `clusters/centralized_netbox/cloud-init/netbox/docker-compose.override.yml.tftpl` — when
  discovery is on, point the `netbox`/`netbox-worker` services at the locally-built plugin image
  (or add a build stanza).
- `clusters/centralized_netbox/outputs.tf` — add `discovery_enabled`, `diode_url`,
  `diode_ingest_client_id`, and fold the Diode metrics URL into `web_urls.all`.
- `clusters/centralized_netbox/scripts/netbox_cli.py` — add `discovery` command + discovery checks
  in `check` (auto-picked up by `just verify-api`).
- `clusters/centralized_netbox/tests/tofu/sizing_and_render.tftest.hcl` — hermetic asserts for both
  flag states (off = no discovery wiring; on = plugin + Diode + agent + sizing bump).
- `clusters/centralized_netbox/tests/netbox/test_netbox_cli.py` — hermetic CLI tests for the new
  `discovery` command + gated `check` behaviour (pytest-httpserver, add a `/api/plugins/diode/`
  route + discovered-IP fixtures).
- `clusters/centralized_netbox/tests/testinfra/conftest.py` — add an `agent` fixture
  (`count`-aware) + a `discovery` fixture from `tofu output`; wait on `discovery-done`.
- `clusters/centralized_netbox/tests/testinfra/` — new `test_discovery.py` (Diode stack + E2E
  discovered objects); guard existing suites so they don't assume the agent VM exists when off.
- `Justfile` — add `netbox-discover` (trigger a scan) + surface the flag in help; `verify-api`
  needs **no** change (it already auto-discovers `netbox_cli.py`).
- `specs/centralized_netbox.md` — cross-link this spec; move the plugin/discovery item out of
  "Future work" into "done (opt-in)".
- `specs/cli-netbox.md` — document the new `discovery` subcommand + gated `check`.

### New Files

- `clusters/centralized_netbox/cloud-init/diode/docker-compose.yaml.tftpl` — the Diode server
  compose (nginx/ingester/reconciler/auth/hydra/redis/postgres), with the metrics ports
  (`9090`–`9092`) published so they're scrapable.
- `clusters/centralized_netbox/cloud-init/diode/env.tftpl` — Diode `.env` from `sample.env` with
  **pinned** `REDIS_PASSWORD`/`POSTGRES_PASSWORD`/`DIODE_*`/`HYDRA_*` secrets + `NETBOX_HOST` +
  `TELEMETRY_METRICS_EXPORTER=prometheus`.
- `clusters/centralized_netbox/cloud-init/diode/client-credentials.json.tftpl` — the three OAuth2
  clients with pinned lab secrets (bypasses `quickstart.sh`).
- `clusters/centralized_netbox/cloud-init/diode/nginx.conf.tftpl` — stock Diode nginx config
  (gRPC + HTTP mux on 80 → host 8080).
- `clusters/centralized_netbox/cloud-init/netbox/plugin_requirements.txt.tftpl` (or inline in
  server cloud-init) — `netboxlabs-diode-netbox-plugin==<pinned>`.
- `clusters/centralized_netbox/cloud-init/netbox/plugins.py.tftpl` — the `PLUGINS`/`PLUGINS_CONFIG`
  configuration fragment mounted into the NetBox container's `configuration/`.
- `clusters/centralized_netbox/cloud-init/agent.yaml.tftpl` — the whole agent VM cloud-init (docker
  + rendered `orb-agent` config + `orb-agent.service`).
- `clusters/centralized_netbox/cloud-init/orb/agent.yaml.tftpl` — the `orb-agent` policy YAML
  (network_discovery over the `/24`, pinned Diode ingest creds).
- `clusters/centralized_netbox/tests/testinfra/test_discovery.py` — live discovery suite.
- (optional) `clusters/centralized_netbox/docs/discovery.md` — a flag-reference page mirroring
  `clusters/centralized_logging/docs/feature-flags.md`.

## Implementation Phases

### Phase 0 — De-risking spikes (blocking, do first)

Cheap experiments that decide the shape of everything else. Do **not** write cluster code until
these resolve.

- **Token confirmation spike (expected to pass).** On a scratch VM, run the target **NetBox 4.4.x**
  image, create a token with an explicit `key=` via `manage.py` (as `netbox-stack.sh` already
  does), and confirm `curl -H "Authorization: Token <key>" /api/status/` returns 200. This is a
  guardrail, not a fork — pinnable v1 tokens are documented to work through 4.4.x (see
  [the token table](#netbox-token-model-across-versions--the-pin-corrected)). If (unexpectedly) it
  fails, drop to **4.2.3** (still v1) before considering the 4.5+ read-back fallback.
- **arm64 image audit (Apple-Silicon lab).** Confirm `linux/arm64` images exist for
  `netboxlabs/diode-ingester|reconciler|auth`, `netboxlabs/orb-agent`,
  `redis/redis-stack-server`, and `oryd/hydra:v26.2.0`. `docker manifest inspect <image> | jq
  '.manifests[].platform'`. Any amd64-only image is a hard blocker on this host (like the
  x86-only `journald-exporter` note in `centralized_logging`) — flag it and pin a working tag.
- **Resource reality check.** Bring up netbox-docker + the Diode stack together on a 6 vCPU / 10G
  VM and confirm it's stable (two Postgres + Redis-stack + Hydra is heavy). Adjust `server_size`
  if needed.
- **Pinned-OAuth2 spike.** Confirm hand-written `client-credentials.json` + `.env` (no
  `quickstart.sh`) yields a working ingest: `diode-auth-bootstrap` registers the pinned clients and
  an `orb-agent` dry-run/real run authenticates. Confirms the deterministic-secret approach.

### Phase 1 — Foundation (flag + plumbing, discovery still inert)

- Add `enable_discovery` (default `false`) and pinned discovery vars to `variables.tf` +
  `terraform.tfvars`. Add the Diode-compatible `netbox_docker_ref` selection.
- Add `local.flags`/thread-through and the `server_size` auto-bump in `main.tf`. No behaviour change
  when off.
- Add the conditional `agent` instance (`count = var.enable_discovery ? 1 : 0`) and the discovery
  `local_file` renders (guarded so they render empty/no-op when off).
- Extend `outputs.tf` (`discovery_enabled`, `diode_url`, `diode_ingest_client_id`).
- Prove the off-path is unchanged: `just check centralized_netbox` stays green.

### Phase 2 — Core Implementation (the discovery stack)

- Write the Diode config templates (`diode/*.tftpl`) with pinned secrets.
- Write the NetBox plugin build wiring (`plugin_requirements.txt`, `plugins.py`, compose build) and
  the `%{ if enable_discovery }` blocks in `server.yaml.tftpl` (custom-image build, plugin migrate,
  Diode compose up, `discovery-done` marker).
- Write the agent VM cloud-init (`agent.yaml.tftpl` + `orb/agent.yaml.tftpl` + `orb-agent.service`).
- Get a real `enable_discovery=true` bring-up working end to end: agent scans the `/24`, discovered
  IPs appear in NetBox.

### Phase 3 — Integration & Polish (verify + docs)

- Extend `netbox_cli.py` (`discovery` cmd + gated `check`) and its hermetic tests.
- Add `test_discovery.py` + conftest fixtures; guard existing testinfra suites for the off-path.
- Add hermetic `tftest` assertions for both flag states.
- Add the `just netbox-discover` recipe; fold the Diode metrics URL into `web_urls`.
- Update `specs/centralized_netbox.md` + `specs/cli-netbox.md`; write `docs/discovery.md`.

## Step by Step Tasks

IMPORTANT: Execute every step in order, top to bottom.

### 1. Run the Phase 0 spikes
- Execute the four spikes above. Record: chosen `netbox_docker_ref` for discovery, whether pinned
  tokens survive the bump, arm64-safe image tags, and stable server sizing.
- If the token spike **fails at every Diode-compatible version**, stop and escalate the fallback
  decision (runtime-generated token) before writing code — it changes Tasks 6–9.

### 2. Add the flag and variables
- In `variables.tf`: `enable_discovery` (bool, default `false`); `netbox_docker_ref_discovery`
  (default a netbox-docker `3.4.x` ref shipping NetBox **4.4.x**, confirmed in Phase 0);
  `diode_ref`/`orb_agent_image` pins; and the
  pinned OAuth2 secrets `diode_ingest_client_secret`, `diode_to_netbox_client_secret`,
  `netbox_to_diode_client_secret` (+ pinned Redis/Postgres/Hydra secrets), each with a
  `validation {}` block and a LAB-ONLY / do-not-copy-to-Proxmox description mirroring
  `netbox_api_token`.
- In `terraform.tfvars`: add `enable_discovery = false` with an explanatory comment.

### 3. Thread the flag through `main.tf`
- Add `local.discovery = var.enable_discovery`; compute `local.effective_netbox_ref =
  var.enable_discovery ? var.netbox_docker_ref_discovery : var.netbox_docker_ref` (off → 4.1,
  on → 4.4.x). Both bands keep the pinned v1 token, so no token code branches on this.
- Add `local.server_size = var.enable_discovery ? {cpus=6,memory="10G",disk="50G"} : var.server`
  (Coroot-style auto-bump) and use it on `multipass_instance.server`.
- Render the Diode + plugin + agent templates into `.rendered/` via `templatefile`/`local_file`,
  passing the pinned secrets, `multipass_instance.server.ipv4`, and the derived `/24`.
- Add `multipass_instance.agent` with `count = var.enable_discovery ? 1 : 0`, its `cloudinit_file`
  pointing at the rendered agent cloud-init.

### 4. Write the Diode server config templates
- `diode/env.tftpl`, `diode/client-credentials.json.tftpl` (three pinned clients + scopes),
  `diode/docker-compose.yaml.tftpl` (publish `9090:9090`, `9091:9090`, `9092:9090` for metrics),
  `diode/nginx.conf.tftpl`. Base them on the upstream community files; substitute pinned secrets +
  `NETBOX_HOST=http://<server_ip>:${netbox_port}`.

### 5. Write the NetBox plugin build wiring
- `netbox/plugin_requirements.txt.tftpl` → `netboxlabs-diode-netbox-plugin==<pinned>`.
- `netbox/plugins.py.tftpl` → `PLUGINS = ["netbox_diode_plugin"]` + `PLUGINS_CONFIG` with
  `diode_target_override: "grpc://<server_ip>:8080/diode"`, `diode_username: "diode"`,
  `netbox_to_diode_client_secret: "<pinned>"`.
- Update `docker-compose.override.yml.tftpl` so, when discovery is on, `netbox`/`netbox-worker`
  build the plugin image (add `Dockerfile-Plugins` + `plugin_requirements.txt` handling per
  netbox-docker's documented plugin build).

### 6. Extend `server.yaml.tftpl`
- Wrap new `write_files` (Diode config, plugin files) and `runcmd`/`netbox-stack.sh` steps in
  `%{ if enable_discovery ~}` … `%{ endif ~}` so the off-path renders identically to today.
- In `netbox-stack.sh` (discovery branch): `docker compose build`; `manage.py migrate
  netbox_diode_plugin`; bring up the Diode compose project under `/opt/diode`; poll Diode nginx
  `:8080` + reconciler health; `touch /var/lib/netbox-bootstrap/discovery-done`. Keep it inside the
  existing idempotent retry loop.

### 7. Write the agent VM cloud-init
- `agent.yaml.tftpl`: docker install, UTC/NTP block (copy from `client.yaml.tftpl`), SSH key,
  render `/opt/orb/agent.yaml`, `orb-agent.service` oneshot running
  `docker run --net=host -v /opt/orb:/opt/orb -e DIODE_CLIENT_ID=... -e DIODE_CLIENT_SECRET=...
  netboxlabs/orb-agent run -c /opt/orb/agent.yaml`, then `touch /var/lib/orb-agent/discovery-done`.
- `orb/agent.yaml.tftpl`: `config_manager.active: local`; `network_discovery` backend;
  `common.diode.target: grpc://<server_ip>:8080/diode` with pinned ingest creds; a
  `network_discovery` policy scoping `targets: [<server_ip>%.*.0/24]` on a schedule; for the
  unprivileged/host case set `scan_types: [connect]` + `skip_host: true` as needed (validated in
  Phase 0).

### 8. Extend outputs + Justfile
- `outputs.tf`: `discovery_enabled`, `diode_url` (`http://<ip>:8080`), `diode_ingest_client_id`,
  the agent in `hosts` (guarded on `count`), and the Diode `:9090/metrics` URL in `web_urls.all`.
- `Justfile`: add `netbox-discover CLUSTER` → `multipass exec <agent> -- sudo systemctl start
  orb-agent.service` (on-demand scan). Update the top-of-file help note that `enable_discovery`
  needs `just recreate`.

### 9. Extend the verification CLI
- Add `netbox_cli.py discovery` — lists discovered objects (e.g. IP Addresses tagged/sourced by
  Diode, or a recent-changes view) and (optionally) hits Diode `:9090/metrics`.
- In `check`: when discovery is enabled (resolved from `tofu output discovery_enabled`), assert the
  `netbox_diode_plugin` is installed (`GET /api/plugins/diode/` or the installed-plugins list) and
  that discovered IPs exist; when disabled, `skip` those rows (don't fail). `just verify-api`
  auto-runs it — no recipe change.

### 10. Write hermetic tests
- `tests/tofu/sizing_and_render.tftest.hcl`: a `run` with `enable_discovery=false` asserting the
  rendered cloud-init has **no** Diode/plugin/agent strings and `count(agent)==0`; a `run` with
  `enable_discovery=true` asserting the plugin install, `PLUGINS_CONFIG`, Diode compose services,
  pinned client ids/scopes, `grpc://…:8080/diode` in the agent config, the network_discovery `/24`
  scope, the server size bump (6/10G/50G), and the agent VM exists.
- `tests/netbox/test_netbox_cli.py`: pytest-httpserver routes for `/api/plugins/diode/` +
  discovered-IP list; assert `discovery` output and that `check` passes/skips correctly per flag.

### 11. Write live tests
- `tests/testinfra/conftest.py`: `agent` fixture (only when `discovery_enabled`), `discovery`
  fixture from `tofu output`; wait on `/var/lib/netbox-bootstrap/discovery-done` (server) and
  `/var/lib/orb-agent/discovery-done` (agent).
- `tests/testinfra/test_discovery.py`: server has the Diode plugin (REST), Diode compose stack
  running (`docker compose -f /opt/diode/docker-compose.yaml ps` healthy), Diode `:9090/metrics`
  responds; **E2E headline** — query NetBox and assert IP Addresses the agent discovered (e.g. the
  gateway/other-VM IPs on the `/24`) are present beyond the two hand-registered VMs. Mark the whole
  module `skip` when `discovery_enabled` is false.
- Guard existing suites (`test_server.py` etc.) so nothing assumes the agent VM exists when off.

### 12. Documentation
- Update `specs/centralized_netbox.md` (move plugin/discovery from Future work → done-opt-in;
  cross-link here) and `specs/cli-netbox.md` (new `discovery` subcommand). Optionally add
  `clusters/centralized_netbox/docs/discovery.md` (flag reference + the version-conflict rationale).

### 13. Validate the whole feature (both flag states)
- Run every command in **Validation Commands** below, off then on, and confirm the acceptance
  criteria.

## Testing Strategy

Mirror the repo's two-layer split (`CLAUDE.md`), and make the flag a **first-class test dimension**
— every layer runs the off-path (must equal today) and the on-path.

- **Layer 0/1 — hermetic (`just check`, no VMs).** `mock_provider "multipass"`, `command = plan`.
  Two `run` blocks over `enable_discovery` false/true (set via `variables {}`), asserting rendered
  cloud-init content, `count`-gated agent instance, pinned OAuth2 client ids/scopes, `grpc` target,
  network_discovery `/24` scope, and the sizing bump. This is where the bulk of confidence comes
  from because the live stack is heavy and slow.
- **Layer 1 — hermetic CLI (`tests/netbox`, pytest-httpserver).** Drive `netbox_cli.py` against a
  fake NetBox exposing `/api/plugins/diode/` + discovered IPs; cover `discovery` output and the
  `check` pass/skip matrix per flag. No `tofu`, no VMs.
- **Layer 2 — live (`just verify` + `just netbox-check`, after `just up`/`recreate`).** With
  discovery **on**: server Diode plugin present, Diode stack healthy, metrics up, and the E2E
  discovered-objects assertion. With discovery **off**: the discovery suite skips and all existing
  self-registration/data-model tests pass unchanged.

**Edge cases to cover:** flag off leaves cloud-init byte-identical (guard against accidental
render drift); agent VM absent when off (`count==0`, `hosts` output has no `agent`); a re-`recreate`
doesn't duplicate NetBox objects (Diode reconciles idempotently, but assert no dupes);
network_discovery finding zero hosts (agent still exits 0, marker written) vs. finding the subnet;
arm64 image-pull failure surfaces as a clear provisioning failure, not a hang.

## Acceptance Criteria

- With `enable_discovery=false`: `just check centralized_netbox` passes; rendered cloud-init and
  every existing hermetic/live test are unchanged (NetBox 4.1, pinned token, self-registration).
- With `enable_discovery=true` (via `just recreate centralized_netbox`): three VMs come up; NetBox
  has `netbox_diode_plugin` installed and reachable at `/api/plugins/diode/`; the Diode server
  stack is running and healthy; the `orb-agent` VM runs a network_discovery scan of the Multipass
  `/24`.
- After a scan, **NetBox contains IP Addresses / objects discovered by the agent** beyond the two
  hand-registered VMs, verifiable via the REST API and `netbox_cli.py discovery`.
- `just netbox-check centralized_netbox` passes on the on-path and cleanly skips discovery rows on
  the off-path; `just verify centralized_netbox` passes in both states.
- Phase 0's token decision is documented in the spec; no random/runtime OAuth2 secrets — all pinned
  and exposed via `tofu output` (lab-only, do-not-copy-to-Proxmox).
- `specs/centralized_netbox.md` and `specs/cli-netbox.md` reflect the feature.

## Validation Commands

Execute these to validate the task is complete:

- `tofu -chdir=clusters/centralized_netbox fmt -check -recursive` — formatting.
- `tofu -chdir=clusters/centralized_netbox validate` — config validity.
- `just check centralized_netbox` — full hermetic gate (fmt + validate + `tofu test`), **must pass
  with the flag off**.
- `tofu -chdir=clusters/centralized_netbox test -test-directory=tests/tofu` — hermetic render/sizing
  asserts for **both** flag states.
- `cd clusters/centralized_netbox/tests/netbox && uv run pytest -v` — hermetic CLI suite (incl. new
  `discovery`/`check` tests).
- `uv run clusters/centralized_netbox/scripts/netbox_cli.py --help` — CLI imports/parses (`python -m
  py_compile` equivalent for a uv single-file script).
- `just recreate centralized_netbox` with `enable_discovery=true` in tfvars — live bring-up of all
  three VMs (cloud-init change requires recreate, not `up`).
- `just verify centralized_netbox` — live testinfra incl. `test_discovery.py`.
- `just netbox-check centralized_netbox` (and `just verify-api centralized_netbox`) — live API
  check; discovery rows pass on / skip off.
- `just netbox-discover centralized_netbox` — trigger an on-demand scan, then re-run `netbox-check`
  to see discovered objects.
- Regression: flip `enable_discovery=false`, `just recreate`, and confirm every original test still
  passes.

## Live validation findings (2026-07-02)

A live `enable_discovery=true` bring-up on the Apple-Silicon host surfaced (and this plan/impl now
fix) four concrete plugin-build bugs that the hermetic layer can't catch, and confirmed one gap:

1. **netbox-docker ships no `Dockerfile-Plugins`.** Only `Dockerfile` exists — the plugin Dockerfile
   is an example you author. Fixed: `netbox-stack.sh` now *generates* one, deriving the base image
   tag from the compose's default `VERSION` (so it tracks `netbox_docker_ref_discovery`).
2. **The `docker.io` apt package has no buildx/BuildKit.** `docker compose build` wants Bake/BuildKit
   and silently hangs. Fixed: build the plugin image with the legacy builder
   (`DOCKER_BUILDKIT=0 docker build -t netbox:latest-plugins`), and the override just references the
   pre-built image (`pull_policy: never`, no `build:` stanza).
3. **The netbox image is `uv`-managed** — there is no `/opt/netbox/venv/bin/pip`. Fixed: install with
   `/usr/local/bin/uv pip install` (the image sets `VIRTUAL_ENV=/opt/netbox/venv`).
4. **Plugin↔NetBox patch pairing matters.** `netboxcommunity/netbox:v4.4-3.4.1` ships NetBox **4.4.5**,
   and plugin **1.7.0 requires ≥ 4.4.10** — it *silently refuses to load* (`plugins: {}`,
   `/api/plugins/diode/` → 404). Fixed: pin `diode_plugin_version = 1.4.1` (compat table: 4.4.0 →
   1.4.x). **Verified live:** with 1.4.1 the plugin loads (`/api/status/` → `netbox_diode_plugin:
   1.4.1`, `/api/plugins/diode/` → 200).

**Confirmed working live:** the custom plugin image builds and NetBox serves the Diode plugin API.
**Still a gap (representative config):** the self-hosted **Diode server stack** did not converge — the
stock `postgres:16-alpine` ignores `POSTGRES_MULTIPLE_DATABASES` (no `hydra` DB), Hydra's `DSN`
isn't wired, and `bootstrap-clients.sh` is a hand-rolled approximation. Bringing Diode fully up
needs the **actual diode-server release's** `docker-compose.yaml` + `.env` (reconciled against the
pinned-secret model), which is a tracked follow-up — not a quick patch.

## Notes

- **The version conflict is smaller than it first looked.** Diode needs NetBox ≥ 4.2.3, and
  pinnable v1 tokens survive through **4.4.x** — so pinning the discovery path at **4.4.x** keeps
  the deterministic-token contract (`netbox_cli`, testinfra, self-registration) with **no** rework.
  The hashed-v2 cliff is **4.5**, not 4.2 (see
  [the token table](#netbox-token-model-across-versions--the-pin-corrected)). The runtime-token
  read-back fallback is only relevant if you deliberately chase 4.5+ and would enlarge Tasks 6/9/11
  — avoid it by staying on 4.4.x.
- **Correct the misleading `variables.tf` comment.** `netbox_docker_ref`'s description says "NetBox
  4.2+ switched to hashed v2 (Bearer) tokens" — that's wrong; it's **4.5+**. NetBox 4.2–4.4.x still
  use pinnable v1 plaintext tokens. Fix the comment (and, if desired, note that 4.4.x is a
  perfectly lab-friendly modern pin — the choice of 4.1 was more conservative than the token
  constraint actually required). Whether to modernize the *default* cluster pin is a separate
  decision from this feature.
- **arm64 is a real risk** on the Apple-Silicon lab host. `netboxlabs/*`, `orb-agent`,
  `redis/redis-stack-server`, and `oryd/hydra` must all publish `linux/arm64`. Treat a missing
  arch like the x86-only `journald-exporter` carve-out in `centralized_logging` — pin a working tag
  or document the limitation (works on amd64 Proxmox).
- **Resource footprint.** Discovery-on is by far the heaviest cluster: ~15 containers across
  netbox-docker + Diode (two Postgres, Redis-stack, Hydra). Hence the 6 vCPU / 10G / 50G server
  auto-bump. Keep the flag **off by default** so casual `just up` stays light.
- **Deterministic secrets, not `quickstart.sh`.** Rendering Diode's `.env` +
  `client-credentials.json` with pinned lab secrets is what keeps the lab hermetic and testable;
  it's the same lab-only pattern as `netbox_api_token`. **Do not** copy any of these pinned secrets
  to Proxmox — generate + inject real ones from a secret store there
  (`orb-agent` also supports Doppler via its `secretsmgr`, noted for the real target).
- **License.** `diode-netbox-plugin` is under the **NetBox Limited Use License 1.0** (not OSS) —
  fine for a private lab, worth noting if this repo is ever distributed.
- **Scope guard.** Headline is `network_discovery` (nmap over the `/24`). `device_discovery`
  (NAPALM) targets network-OS drivers, not Ubuntu VMs — leave as future work. `snmp_discovery` /
  `worker` backends likewise out of scope.
- **New Python deps** for the CLI/tests are minimal — `netbox_cli.py` already carries `pynetbox` +
  `httpx`, which cover querying discovered objects and hitting Diode `:9090/metrics`. No Diode read
  SDK exists (mirrors OpenObserve's raw-`httpx` approach), so no `uv add` of a Diode client is
  needed. If a hermetic gRPC assertion is ever wanted, add a dry-run-JSON check instead of a gRPC
  client.
```
