# Plan: fleet-edge Traefik (dynamic file provider, host CLI hot-push)

Status: **planned** · Task type: **feature** · Complexity: **complex**
Edge lives in: `centralized_pki` (extends the existing Traefik) · Reference precedent: the
Prometheus scrape-target hot-push in `Justfile` (`up-connected`, §5) and `specs/cross-cluster.md`
DNS/rewrite hub: `centralized_dns` (AdGuard Home) · k0s ingress: `centralized_logging` (ingress-nginx)

## Task Description

Make the Traefik instance already running in `centralized_pki` the **single reverse-proxy edge
for the whole fleet** — every human-facing service in every cluster (Grafana, Prometheus,
OpenObserve, NetBox, AdGuard Home UI, UniFi, Coroot, plus the existing Authelia/Vaultwarden) reachable
through it over TLS at a stable hostname, instead of each service being hit by raw `IP:port`.

The routing table must be **updatable dynamically and remotely** — no VM recreate, no Traefik
restart. We do this the way the repo already hot-pushes `prometheus.yml`: a host-run **uv single-file
CLI** (`traefik_cli.py`) reads every cluster's `tofu output`, renders a fleet dynamic-config file, and
`scp`s it onto the Traefik VM, where Traefik's **file provider** (`watch: true`) hot-reloads it. The
generated file sits in a watched directory *alongside* pki's existing `dynamic.yaml`, which is left
untouched.

**k0s clusters are treated as a black-box ingress, not re-implemented.** `centralized_logging`'s k0s
node already runs `ingress-nginx` (hostNetwork `:80`/`:443`) and exposes Coroot on NodePort `30080`.
The fleet Traefik does **not** try to become the in-cluster ingress — it routes to the k0s edge
(NodePort, or ingress-nginx with a Host-rewrite), letting Kubernetes own everything inside the node.
This mirrors the user's requirement: "on the k0s clusters, use whatever the ingress is instead."

## Objective

After `just up-connected` (or the new `just traefik-sync`), a browser pointed at
`https://grafana.lab.theblacktonystark.com`, `https://netbox.lab.…`, `https://observe.lab.…`,
`https://dns.lab.…`, `https://coroot.lab.…`, etc. reaches the right service in the right cluster
through one Traefik edge, with TLS served by step-ca (existing default cert / LE-staging wildcard) and
optional Authelia SSO. Adding, removing, or re-IPing a service is a single `just traefik-sync` away —
no recreate, no restart. `just check centralized_pki`, `just verify centralized_pki`, and a new
`just traefik-check` all pass.

## Problem Statement

Every cluster today publishes its human dashboards as bare `http://<dhcp-ip>:<port>` URLs (the
`web_urls.core` output consumed by `just open`). That has three problems for a fleet that is meant to
feel like a real environment:

1. **No stable names.** Multipass hands out DHCP IPs that churn on every `just up`, so bookmarks and
   inter-service links rot. There is no `grafana.<domain>` — only `192.168.252.x:3000`.
2. **No single TLS/SSO edge.** `centralized_pki` already solved TLS (step-ca leaf / LE-staging
   wildcard) and SSO (Authelia forward-auth) — but only for `auth.` and `warden.`. Every other
   cluster's UI is plaintext HTTP on a random port, outside that edge.
3. **No dynamic remote update path.** pki's Traefik reads a **static** `dynamic.yaml` baked into
   cloud-init at boot. Re-pointing a router at a new backend IP means editing a `.tftpl` and
   `just recreate` — a full VM rebuild — which is exactly the friction the user is trying to escape.

The hard part is **not** connectivity (flat `/24`, every UI binds `0.0.0.0`) nor TLS (already solved).
The two missing pieces mirror `specs/cross-cluster.md` precisely:

1. **Cross-state endpoint discovery** — pki's `main.tf` can only see its own `multipass_instance`
   resources, so it cannot learn Grafana's or NetBox's DHCP IP to write a router for it.
2. **A remote, hot, no-restart update mechanism** — so the routing table tracks the fleet as clusters
   come and go, without rebuilding the edge VM.

## Solution Approach

Reuse two patterns the repo already ships, so this adds **zero new stateful services**:

- **Traefik's file provider in `directory`/`watch` mode** (pki already runs the file provider with
  `watch: true`). Point it at a directory `/etc/traefik/dynamic/`. pki's own base routes stay in
  `dynamic.yaml`; the fleet routes land in a **separate** `fleet.yaml` that is generated and pushed
  from the host. Traefik merges every `*.yaml` in the directory and hot-reloads on any change.
- **The `prometheus.yml` hot-push** (`Justfile` `up-connected` §5, lines ~206–218: `tofu apply`
  re-renders → `scp` onto the running VM → `cp` + container reload, **never recreate**). We do the
  identical dance for `fleet.yaml`, driven by a host CLI instead of the orchestrator.

### The discovery + render + push loop

```
                          host (developer laptop)
  ┌───────────────────────────────────────────────────────────────────────┐
  │  traefik_cli.py sync                                                     │
  │    for each cluster dir with a main.tf:                                  │
  │      tofu -chdir=clusters/<c> output -json reverse_proxy_routes   ──┐    │
  │    aggregate routes ─► render fleet.yaml (routers + services)       │    │
  │    scp fleet.yaml  ubuntu@<pki_services_ip>:/tmp/fleet.yaml         │    │
  │    ssh 'sudo cp /tmp/fleet.yaml /opt/stack/traefik/dynamic/'  ──────┘    │
  └───────────────────────────────────────────────────────────────────────┘
                                   │  (no recreate, no restart)
                                   ▼
        centralized_pki  services VM  ──  Traefik v3.1  (file provider, watch dir)
         /opt/stack/traefik/dynamic/dynamic.yaml   (base: auth., warden.)   [in cloud-init]
         /opt/stack/traefik/dynamic/fleet.yaml     (grafana., netbox., …)   [hot-pushed] ◄── reloads instantly
                                   │
      ┌────────────────────────────┼───────────────────────────────────────────┐
      ▼                            ▼                                            ▼
  monitoring VM               netbox VM                         logging k0s node
  Grafana :3000               NetBox :8000                      ingress-nginx :80  /  NodePort :30080
  Prometheus :9090            (Virtualization host)             (Coroot UI — Traefik routes to the
  OpenObserve :5080                                              k0s ingress, does NOT replace it)
```

### The routing contract: a per-cluster `reverse_proxy_routes` output

Rather than have the CLI brittle-parse each cluster's `web_urls` array, each cluster publishes an
explicit, hermetically-testable contract — a new OpenTofu output mirroring how `centralized_monitoring`
already exposes `metrics_targets` and how `cross-cluster` consumes `hosts`:

```hcl
output "reverse_proxy_routes" {
  description = "Routes the fleet-edge Traefik should publish for this cluster. Consumed by scripts/traefik_cli.py."
  value = [
    { host = "grafana",  ip = multipass_instance.server.ipv4, port = 3000, scheme = "http", sso = false, k0s = false },
    { host = "observe",  ip = multipass_instance.server.ipv4, port = 5080, scheme = "http", sso = false, k0s = false },
    { host = "prom",     ip = multipass_instance.server.ipv4, port = 9090, scheme = "http", sso = true,  k0s = false },
  ]
}
```

Field semantics:

| Field | Meaning |
|---|---|
| `host` | left-most label; the router rule becomes `Host(\`${host}.${domain}\`)` (domain from pki) |
| `ip` / `port` | upstream `loadBalancer` server (`${scheme}://${ip}:${port}`) |
| `scheme` | `http` (default) or `https` (for services that already terminate TLS internally) |
| `sso` | `true` → attach the Authelia forward-auth middleware (gate behind SSO) |
| `k0s` | `true` → this backend is a Kubernetes ingress/NodePort; apply the k0s handling below |

The CLI aggregates `reverse_proxy_routes` across every cluster whose apply is in state, injects pki's
`domain`, and renders one `fleet.yaml`. A cluster with no such output (or an empty list) contributes
nothing — default fleet stays turnkey; wiring is **purely additive**.

### k0s handling (route to the ingress, don't replace it)

Coroot lives behind the k0s node's ingress-nginx (hostNetwork `:80`/`:443`) and a NodePort (`30080`).
The fleet Traefik treats the k0s node as an opaque upstream. Two supported shapes, both encoded by
`k0s = true` in the route:

- **NodePort (recommended, simplest).** Service upstream = `http://<k0s_ip>:30080`. Coroot's UI serves
  directly on the NodePort with no Host-matching, so no header games are needed. This is what
  `coroot_nodeport` (default `30080`) already exposes.
- **ingress-nginx (when `enable_ingress`).** ingress-nginx routes by the ingress `Host` (`coroot.local`
  by default, `var.coroot_host`). Traefik must rewrite the upstream Host header or ingress-nginx returns
  404. The renderer emits a per-route `headers` middleware (`customRequestHeaders: { Host: coroot.local }`)
  plus `passHostHeader: false` on the service. The route's `k0s_ingress_host` field carries that value.

Either way, **Kubernetes owns everything inside the node** — the fleet Traefik only forwards to the k0s
edge. This is the explicit design line the user drew.

### DNS: wildcard rewrite on the AdGuard hub

Host-based routing needs `*.lab.<domain>` to resolve to the Traefik VM. `centralized_dns` (AdGuard Home,
the resolver every VM already points at via `dns_server`) is the natural place: add **one** AdGuard DNS
rewrite `*.${domain} → <pki_services_ip>`. AdGuard's `filtering.rewrites` supports wildcards. This is a
new opt-in var `traefik_edge_ip` on `centralized_dns`; when set, the rewrite is templated into
`AdGuardHome.yaml`. `up-connected` discovers pki's services IP and wires it (hot-push onto the running
AdGuard, mirroring the DNS self-telemetry hot-push already in `up-connected` §4). For a laptop that
doesn't use AdGuard as its resolver, the CLI also prints an `/etc/hosts` block (`just traefik-hosts`).

## Relevant Files

Use these files to complete the task:

- `clusters/centralized_pki/cloud-init/traefik/traefik.yaml.tftpl` — **edit.** Switch the file provider
  from `filename: /etc/traefik/dynamic.yaml` to `directory: /etc/traefik/dynamic` (keep `watch: true`).
- `clusters/centralized_pki/cloud-init/traefik/dynamic.yaml.tftpl` — **move/rename** its rendered target
  into the watched directory (`dynamic/dynamic.yaml`); content unchanged (base auth./warden. routes).
- `clusters/centralized_pki/cloud-init/services.yaml.tftpl` — **edit.** Write the base dynamic config to
  `/opt/stack/traefik/dynamic/dynamic.yaml`; `mkdir -p /opt/stack/traefik/dynamic`; ship a **seed**
  empty `fleet.yaml` so the directory provider is valid before the first sync.
- `clusters/centralized_pki/main.tf` — **edit.** Adjust the `local_file`/`templatefile` render path for
  the moved dynamic.yaml; nothing else in pki changes (the edge is otherwise already built).
- `clusters/centralized_pki/outputs.tf` — **edit.** Add pki's own `reverse_proxy_routes` (auth., warden.)
  and keep exposing `domain` + `services_ipv4` (both already present) for the CLI.
- `clusters/centralized_pki/scripts/_pki_common.py` — **reference/extend.** Its `tofu output -json`
  helper + `resolve_target` pattern is the model for the new CLI's IP resolution.
- `clusters/{centralized_monitoring,centralized_netbox,centralized_dns,centralized_unifi,centralized_logging}/outputs.tf`
  — **edit.** Add a `reverse_proxy_routes` output per cluster (monitoring: grafana/observe/prom; netbox:
  netbox; dns: adguard; unifi: unifi; logging: coroot with `k0s = true`).
- `clusters/centralized_dns/cloud-init/adguard/AdGuardHome.yaml.tftpl` + `variables.tf` — **edit.** Add
  `traefik_edge_ip` var and a wildcard `filtering.rewrites` entry (`*.${domain} → traefik_edge_ip`).
- `Justfile` — **edit.** Add `traefik-sync`, `traefik-check`, `traefik-targets`, `traefik-hosts`
  recipes; call `traefik-sync` at the tail of `up-connected` (after all consumers are up).
- `specs/cross-cluster.md` — **reference.** The `.auto.tfvars.json` discovery + hot-push design this
  mirrors; add a back-reference note.
- `specs/centralized_pki.md`, `clusters/centralized_pki/docs/feature-flags.md` — **edit.** Document the
  edge role and the new recipes.

### New Files

- `clusters/centralized_pki/scripts/traefik_cli.py` — uv single-file CLI (typer + rich). Subcommands:
  `targets` (print resolved routes, no push), `render` (write `fleet.yaml` locally, no push), `sync`
  (render + scp + install onto the running VM), `check` (render + validate every backend is reachable;
  exits nonzero on failure — the CI-style probe every other `*_cli.py` has), `hosts` (print an
  `/etc/hosts` block). Resolves IPs from `tofu output` via the shared `_pki_common` helper (or
  `--pki-ip`).
- `clusters/centralized_pki/cloud-init/traefik/fleet.yaml.seed` — a minimal valid empty dynamic doc
  (`http: {routers: {}, services: {}}`) shipped in cloud-init so the directory provider is happy at boot
  before the first `traefik-sync`.
- `clusters/centralized_pki/tests/traefik/` — hermetic pytest suite for the renderer (pytest-httpserver
  for the `check` probe; pure-function tests for route → YAML rendering). Mirrors `tests/tls/`.
- `clusters/centralized_pki/tests/tofu/` — extend the existing `sizing_and_render.tftest.hcl` (or add a
  `reverse_proxy.tftest.hcl`) asserting each cluster's `reverse_proxy_routes` output shape under
  `mock_provider`.

## Implementation Phases

### Phase 1: Foundation — directory provider + routing contract (hermetic only)

Convert pki's file provider to `directory` mode with the base routes moved into the watched dir and a
seed `fleet.yaml`, and add the `reverse_proxy_routes` output to every cluster. All of this is provable by
`just check` with **no VM** — `mock_provider` + `command = plan` asserting the output shape and the
rendered cloud-init paths. Nothing behavioral yet; the edge still serves exactly auth./warden.

### Phase 2: Core Implementation — the host CLI + render/sync/check

Write `traefik_cli.py`: discover routes across clusters, render `fleet.yaml` (routers, services,
Authelia middleware attach for `sso`, k0s NodePort/ingress-Host handling), scp + install with the exact
hot-push idiom, and a reachability `check`. Wire the `just traefik-*` recipes. Add the AdGuard wildcard
rewrite var to `centralized_dns`.

### Phase 3: Integration & Polish — orchestration, DNS, docs, live e2e

Call `traefik-sync` at the tail of `up-connected`; hot-push the AdGuard wildcard rewrite; add the live
testinfra assertions (a `curl --resolve grafana.<domain>:443:<pki_ip>` reaches Grafana through the edge);
update `feature-flags.md`, `centralized_pki.md`, and the `web_urls`/`just open` docs to prefer hostnames.

## Step by Step Tasks

IMPORTANT: Execute every step in order, top to bottom.

### 1. Switch pki's Traefik file provider to a watched directory
- In `traefik.yaml.tftpl`, replace `providers.file.filename: /etc/traefik/dynamic.yaml` with
  `providers.file.directory: /etc/traefik/dynamic` (keep `watch: true`).
- In `services.yaml.tftpl`, change the base dynamic config `write_files` path to
  `/opt/stack/traefik/dynamic/dynamic.yaml`; add `mkdir -p /opt/stack/traefik/dynamic` to `runcmd`
  (before `docker compose up`); ship `fleet.yaml.seed` to `/opt/stack/traefik/dynamic/fleet.yaml`.
- Adjust `main.tf`'s `local_file`/render wiring for the moved path; leave the compose volume mount
  (`/opt/stack/traefik:/etc/traefik`) as-is (the whole dir is already mounted).
- Verify hermetically: `just check centralized_pki` still passes; the plan shows the new paths.

### 2. Add the `reverse_proxy_routes` output contract to every cluster
- `centralized_pki/outputs.tf`: `auth.` (sso optional), `warden.` (already routed; declare it so the
  contract is complete and the CLI is the single source of truth).
- `centralized_monitoring/outputs.tf`: `grafana` :3000, `observe` :5080, `prom` :9090 (`sso = true`).
- `centralized_netbox/outputs.tf`: `netbox` :8000 (use the existing `netbox_port` var).
- `centralized_dns/outputs.tf`: `adguard` (AdGuard UI :3000).
- `centralized_unifi/outputs.tf`: `unifi` (controller UI port).
- `centralized_logging/outputs.tf`: `coroot` with `ip = k0s_ipv4`, `port = coroot_nodeport` (30080),
  `k0s = true`, `k0s_ingress_host = coroot_host` (only consulted when routing via ingress).
- Gate each entry on the relevant feature flag where applicable (e.g. Coroot only when `enable_coroot`).

### 3. Add hermetic tests for the contract
- Extend `tests/tofu/` in each edited cluster: under `mock_provider` + `command = plan`, assert the
  `reverse_proxy_routes` output has the expected `host`/`port`/`k0s` values, and that flag-gated routes
  are absent when the flag is off.

### 4. Write `traefik_cli.py` (discovery + render)
- uv single-file header (PEP 723), `typer` + `rich` + `pyyaml`, mirroring `tls_cli.py`.
- Import `_pki_common` for `tofu output -json` + IP resolution; add a `discover_routes()` that globs
  `clusters/*/` (skip dirs without `main.tf`), runs `tofu output -json reverse_proxy_routes` per cluster,
  tolerates clusters not applied (empty), and injects pki's `domain`.
- `render_fleet(routes, domain) -> str`: emit Traefik dynamic YAML — one router per route
  (`Host(\`${host}.${domain}\`)`, `entryPoints: [websecure]`, `tls: {}`), one service
  (`${scheme}://${ip}:${port}`), attach the `authelia` middleware when `sso`, and for `k0s` routes emit
  the NodePort service (or the Host-rewrite `headers` middleware + `passHostHeader: false` when an
  ingress host is set).
- `targets` and `render` subcommands (print / write locally). No network side effects yet.

### 5. Add `sync` + `check` + `hosts` subcommands
- `sync`: `render` → write `.rendered/fleet.yaml` → `scp` to `ubuntu@<pki_ip>:/tmp/fleet.yaml` →
  `ssh 'sudo cp /tmp/fleet.yaml /opt/stack/traefik/dynamic/fleet.yaml'`. **No docker restart** — the
  file-watch reloads it. Use the same `ssh_opts`/`ssh_key` the Justfile uses.
- `check`: render, then for each route issue `curl --resolve <host>.<domain>:443:<pki_ip>
  https://<host>.<domain>/` (or an httpx equivalent) and assert a non-5xx/non-connection-error; exit
  nonzero on any failure (CI-style, matching `*-check` recipes).
- `hosts`: print an `/etc/hosts` block mapping every `<host>.<domain>` to `<pki_ip>` for laptops not
  using AdGuard.

### 6. Add the `just traefik-*` recipes
- `traefik-sync`, `traefik-targets`, `traefik-render`, `traefik-check`, `traefik-hosts` — thin wrappers
  running `uv run clusters/centralized_pki/scripts/traefik_cli.py <sub>` from the repo root. Follow the
  existing `*-check`/`open` recipe style; ensure `verify-api` still skips this CLI cleanly (it has a
  `check`, so it is *not* excluded like `heimdall_cli`; confirm the auto-discovery includes it).

### 7. Wire the AdGuard wildcard rewrite (DNS)
- `centralized_dns/variables.tf`: add `traefik_edge_ip` (string, default `""`).
- `AdGuardHome.yaml.tftpl`: when non-empty, add a `filtering.rewrites` entry
  `{ domain = "*.${domain}", answer = traefik_edge_ip }` (thread `domain` in — reuse pki's default or a
  shared var). Hermetic test: rewrite present when set, absent when `""`.

### 8. Orchestrate in `up-connected` + hot-push the DNS rewrite
- At the tail of `up-connected` (after all consumers are up and IPs known): discover pki's services IP,
  run `traefik_cli.py sync`, then hot-push the AdGuard rewrite (set `traefik_edge_ip`, `tofu apply`
  re-renders `AdGuardHome.yaml`, scp onto the running DNS VM, reload AdGuard) — reusing the DNS
  self-telemetry hot-push block (`up-connected` §4) as the template.

### 9. Add live testinfra coverage
- In `centralized_pki/tests/testinfra/`, add a test that (given the fleet is up) hits at least one
  cross-cluster route through the edge: `curl --resolve grafana.<domain>:443:<pki_ip> -k
  https://grafana.<domain>/api/health` returns 200. Gate it to skip when the peer cluster isn't applied.

### 10. Documentation
- Update `specs/centralized_pki.md` (edge role), `clusters/centralized_pki/docs/feature-flags.md`
  (the new recipes + routing contract), and add a back-reference from `specs/cross-cluster.md`.
- Note in `CLAUDE.md`'s cluster paragraph that `centralized_pki`'s Traefik is the **fleet reverse-proxy
  edge**, hot-updated via `just traefik-sync` (mirrors the Prometheus scrape hot-push).

### 11. Validate end to end
- Run the full validation command block below; confirm hermetic passes with no VMs, then (if VMs are
  launchable) `just up-connected` → `just traefik-check` green and a browser reaches a hostname.

## Testing Strategy

Two-layer split, mirroring the rest of the repo:

- **Hermetic** (`just check <cluster>` + `tests/traefik/`, no VMs):
  - Each cluster's `reverse_proxy_routes` output shape under `mock_provider` + `command = plan`;
    flag-gated routes present/absent per flag.
  - pki cloud-init renders the base dynamic config into `/opt/stack/traefik/dynamic/` and ships the seed
    `fleet.yaml`; the static config uses `directory:` not `filename:`.
  - `traefik_cli.py` pure functions: `render_fleet()` given a fixed route list produces expected YAML
    (router rules, service URLs, `authelia` middleware attached iff `sso`, NodePort vs ingress-Host for
    `k0s`). No `tofu`/`ssh` — feed routes directly.
  - `check`'s probe against `pytest-httpserver` (200 → pass, 503/connrefused → nonzero exit).
  - AdGuard rewrite templated iff `traefik_edge_ip` set.
- **Live** (`just verify centralized_pki` / `just traefik-check`, running VMs):
  - `curl --resolve <host>.<domain>:443:<pki_ip>` reaches the real backend through the edge for a
    representative route per cluster (Grafana, NetBox, AdGuard UI, Coroot-via-k0s).
  - `traefik-check` exits 0 with the full fleet up; exits nonzero if a backend is down.

Edge cases to cover: a cluster in the routing contract but **not applied** (CLI must skip, not crash);
two clusters claiming the same `host` label (CLI must detect + fail loudly); a `k0s` route when
`enable_ingress` is off (fall back to NodePort); `enable_letsencrypt_staging` on vs off (routers set
`tls: {}` either way — no change needed, but assert it).

## Acceptance Criteria

- `just check centralized_pki` and `just check` for every edited cluster pass (hermetic, no VMs).
- Each participating cluster exposes a `reverse_proxy_routes` output with correct host/ip/port/k0s.
- `traefik_cli.py render` produces valid Traefik dynamic YAML from live `tofu output`; `sync` installs
  `fleet.yaml` onto the running pki VM **without a recreate or a `docker restart`**, and Traefik picks it
  up via file-watch (visible in the Traefik dashboard `:8080`).
- With the fleet up, `https://grafana.<domain>`, `https://netbox.<domain>`, `https://observe.<domain>`,
  `https://dns.<domain>`, and `https://coroot.<domain>` each reach the correct backend over TLS through
  the single edge; the Coroot route reaches the k0s ingress/NodePort (Traefik does not re-implement it).
- `just traefik-check` exits 0 when all backends are reachable, nonzero when one is down.
- `up-connected` runs `traefik-sync` at its tail and the AdGuard wildcard rewrite resolves `*.<domain>`
  to the edge; `just traefik-hosts` prints a working `/etc/hosts` fallback.
- Adding/removing a route (edit a cluster's output → `just traefik-sync`) updates routing live, no
  restart.

## Validation Commands

Execute these to validate the task is complete:

- `just check centralized_pki` — hermetic: pki tofu fmt + validate + test (directory provider + base
  routes render; seed fleet.yaml present).
- `for c in centralized_monitoring centralized_netbox centralized_dns centralized_unifi centralized_logging; do just check $c; done`
  — every cluster's `reverse_proxy_routes` output validates hermetically.
- `cd clusters/centralized_pki/tests/traefik && uv run pytest -v` — renderer + probe unit tests.
- `uv run clusters/centralized_pki/scripts/traefik_cli.py targets` — prints the resolved fleet routes
  from live `tofu output` (run after at least `just up centralized_pki`).
- `uv run clusters/centralized_pki/scripts/traefik_cli.py render` — writes a valid `fleet.yaml`; eyeball
  or `python -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' .../fleet.yaml`.
- `just traefik-sync && just traefik-check` — (fleet up) push routes + assert every backend reachable;
  expect exit 0.
- `ruff check clusters/centralized_pki/scripts/traefik_cli.py` — lint the new CLI.
- `curl -sk --resolve grafana.lab.theblacktonystark.com:443:$(tofu -chdir=clusters/centralized_pki output -json hosts | jq -r '.services.ipv4') https://grafana.lab.theblacktonystark.com/api/health`
  — Grafana reached through the edge (expects `{"database":"ok",...}`).

## Notes

- **New Python deps** for `traefik_cli.py` (declare in its PEP 723 inline block; no repo-wide install):
  `typer`, `rich`, `pyyaml`, `httpx`. Mirror `clusters/centralized_pki/scripts/tls_cli.py`'s header and
  its `pyproject.toml`/`uv.lock` test setup for the hermetic suite.
- **Why file provider over Redis/HTTP (decided).** Redis is the "lowest-friction remote KV" answer, but
  it adds a stateful store that must be re-seeded on every `just recreate` (ephemeral) and a container to
  run — friction the repo's declarative, git-tracked, hot-push ethos avoids. The file provider + host-CLI
  push reuses the **exact** `prometheus.yml` hot-push already proven in `up-connected`, needs no new
  service, keeps the routing table diffable, and is still fully "remote + dynamic" (push from any host
  with SSH + `tofu`). Revisit Redis/HTTP only if a non-host client ever needs to mutate routes.
- **Why extend pki, not a new cluster (decided).** The edge belongs where TLS (step-ca) and SSO
  (Authelia forward-auth) already live. A `centralized_traefik` cluster would duplicate both. pki already
  runs Traefik v3.1 with `:80/:443/:8080` published — the fleet role is purely additive config.
- **Traefik v3.1 docker provider is intentionally avoided** (see the compose header: v3.1's docker
  provider speaks an API modern Docker ≥28 rejects). The file provider is the sanctioned mechanism here —
  another reason the file-provider design fits.
- **Ordering / recreate rules apply.** Editing pki cloud-init (Step 1) needs `just recreate
  centralized_pki` once (per CLAUDE.md — a `local_file` content change alone does not recreate the VM).
  After that, all route changes are hot (`traefik-sync`), never a recreate. The AdGuard rewrite hot-push
  also avoids a DNS-hub recreate so the resolver IP the fleet points at never churns.
- **Security.** These are throwaway lab VMs; the edge serves step-ca-issued TLS (self-signed root) or
  LE-staging — browsers will warn unless the step-ca root is trusted. `sso = true` routes (e.g.
  Prometheus, Traefik dashboard) gate behind Authelia; default `sso = false` leaves dashboards open on
  the lab subnet, matching current behavior. Do not carry the lab's open-by-default posture to Proxmox.
- **Future work.** (1) Drive routes from NetBox instead of `tofu output` (each VM self-registers; the CLI
  reads the NetBox API — the same evolution `cross-cluster.md` proposes for Prometheus `http_sd`).
  (2) A Traefik `http` provider pointed at a tiny read-only endpoint the CLI publishes, eliminating the
  scp. (3) Per-service `IngressRoute` CRDs if a cluster ever runs Traefik *as* its k0s ingress.
