# Plan: Install Netdata on every VM (all clusters)

## Task Description

Install the [Netdata](https://www.netdata.cloud/) real-time monitoring agent on **every VM
across all three clusters** — `centralized_logging` (central, k0s, docker), `centralized_monitoring`
(server, k0s), and `centralized_netbox` (server, client): **7 VMs total**. Netdata provides
per-second host / container / systemd-service / journal metrics with a zero-config built-in
dashboard on `:19999`, and exposes a Prometheus endpoint (`/api/v1/allmetrics?format=prometheus`)
that the two clusters running a live Prometheus scrape.

This is **not** greenfield. `centralized_monitoring` already ships an `enable_netdata` bool
(default `true`) that installs Netdata on **only its k0s VM**
(`clusters/centralized_monitoring/cloud-init/k0s-client.yaml.tftpl:170-173`) and scrapes it
(`cloud-init/prometheus/prometheus.yml.tftpl`). This task **generalizes that existing pattern** to
every VM in every cluster, following the repo's established "opt-in observability tool behind a
`bool` flag, tested in both layers" shape (the direct template is `specs/coroot.md`).

## Objective — target UX

```sh
# defaults: enable_netdata = true everywhere
just recreate centralized_logging      # cloud-init change ⇒ recreate, NOT up
just recreate centralized_monitoring
just recreate centralized_netbox
just verify  centralized_logging        # live testinfra asserts netdata running + :19999 up
open http://<any-vm-ip>:19999           # built-in Netdata dashboard on every VM

# opt out for a cluster:
tofu -chdir=clusters/centralized_netbox apply -var enable_netdata=false
```

## Problem Statement

1. **Uneven coverage.** Netdata runs on exactly one VM today; the other 6 have no real-time agent,
   and `centralized_netbox` has **zero** observability (no exporters, no flag machinery at all).
2. **Preserve the two-layer test discipline.** The rollout must be gated by a per-cluster `bool`
   so hermetic tests can assert "flag off ⇒ no Netdata artifact renders" and live tests can
   skip-not-fail when disabled — mirroring `enabled_exporters` / `enabled_features`.
3. **Lab-safe defaults.** No Netdata Cloud connection (no claim token / secret), anonymous
   telemetry disabled, auto-updates pinned off — this is a throwaway Multipass lab, not Proxmox.
4. **Respect each cluster's Prometheus stance.** Wire a scrape job only where a Prometheus already
   exists and scrapes locally (`centralized_monitoring`, `centralized_logging`); `centralized_netbox`
   has no Prometheus, so Netdata there is local-dashboard-only.

## Solution Approach

- **Per-cluster `enable_netdata` bool, default `true`.** Netdata on all 7 VMs by default,
  disable-able per cluster. `centralized_monitoring` already has the flag; add it to
  `centralized_logging` and bootstrap the whole flag pattern into `centralized_netbox`.
- **One canonical install block** (below) in each VM's cloud-init `runcmd`, gated by
  `%{ if enable_netdata ~}…%{ endif ~}` — the same idiom used for every exporter.
- **Flag-gated Prometheus scrape** added to the monitoring server's compose Prometheus and to the
  logging docker VM's inline Prometheus (`__SELF_IP__` boot substitution). Netbox: no scrape.
- **Both test layers**: hermetic `run` blocks in `tests/tofu/sizing_and_render.tftest.hcl`
  (flag-off asserts absence; default asserts render + valid YAML), and a new live
  `tests/testinfra/test_netdata.py` per cluster gated by a skip fixture.

### Canonical install block (verified against the install + telemetry docs)

Standardize every cluster's `runcmd` on this — an upgrade of monitoring's current one-liner that
adds `--non-interactive --stable-channel --no-updates` and a defense-in-depth opt-out file:

```yaml
%{ if enable_netdata ~}
  # netdata — real-time agent (:19999, /api/v1/allmetrics?format=prometheus).
  # Standalone/local-only: no --claim-token (no Netdata Cloud), telemetry disabled, updates pinned.
  - mkdir -p /etc/netdata && touch /etc/netdata/.opt-out-from-anonymous-statistics
  - curl -sSLf https://get.netdata.cloud/kickstart.sh -o /tmp/netdata-kickstart.sh && DO_NOT_TRACK=1 sh /tmp/netdata-kickstart.sh --non-interactive --stable-channel --disable-telemetry --no-updates --dont-wait || true
%{ endif ~}
```

Notes on the flags (see the install + telemetry references):
- `--non-interactive` / `--dont-wait` — unattended, no prompts (required in cloud-init).
- `--stable-channel` — stable release, not nightly.
- `--disable-telemetry` + `DO_NOT_TRACK=1` + the `.opt-out-from-anonymous-statistics` file — three
  independent opt-outs; any one disables anonymous statistics.
- `--no-updates` — pin the version; no self-updating cron in a throwaway VM.
- No `--claim-token` / `--claim-url` ⇒ the agent stays **standalone** (not connected to Netdata Cloud).
- `|| true` — a kickstart hiccup must never fail first boot; the live test catches a real failure.
- kickstart auto-detects arm64 and prefers native packages; config lives in `/etc/netdata`
  (`edit-config` tool), default listen port `19999`.

### Flag-gated Prometheus scrape job

Added to each cluster's **real** Prometheus config (targets = every VM in that cluster):

```yaml
%{ if enable_netdata ~}
  - job_name: netdata
    metrics_path: /api/v1/allmetrics
    params: { format: ["prometheus"] }
    honor_labels: true
    static_configs:
      - targets: ["<vm_ip>:19999", ...]
%{ endif ~}
```

## Relevant Files

### `centralized_monitoring` (flag exists — extend it to the server VM)
- `cloud-init/server.yaml.tftpl` — **add** the canonical install block (server has none today).
- `cloud-init/k0s-client.yaml.tftpl:170-173` — replace the existing one-liner with the canonical block.
- `cloud-init/prometheus/prometheus.yml.tftpl` — extend the existing `netdata` job to include the
  **server** IP alongside the k0s IP.
- `outputs.tf` (~line 69) — add the server `:19999` URL to the flag-gated `web_urls` candidates.
- `main.tf:41` — no change (`enable_netdata` already in `local.flags`); confirm the server
  `templatefile` merges `local.flags`.

### `centralized_logging` (add the flag; install on all 3 VMs; scrape via docker VM)
- `variables.tf` — new `variable "enable_netdata" { type = bool, default = true }`.
- `main.tf:18-29` — add `enable_netdata = var.enable_netdata` to `local.flags` (flows into
  `enabled_exporters`, consumed by `tests/testinfra/conftest.py`).
- `cloud-init/{central,k0s-client,docker-client}.yaml.tftpl` — add the canonical install block to all three.
- `cloud-init/docker-client.yaml.tftpl:122-171` — add a flag-gated `logging-netdata` job to the inline
  scrape config: `["${central_ip}:19999","__SELF_IP__:19999","${k0s_ip}:19999"]` (matches the existing
  `logging-*` jobs + the `__SELF_IP__` boot substitution at `:225`).
- `cloud-init/prometheus/logging-scrape.yml` — add a `logging-netdata` reference job (cross-cluster artifact).
- `cloud-init/prometheus/alert.rules.yml` — optional `NetdataDown` rule (reference artifact, keep style).

### `centralized_netbox` (bootstrap flag machinery; install on both VMs; no scrape)
- `variables.tf` — new `enable_netdata` bool (default `true`).
- `main.tf` — introduce a minimal `local.flags = { enable_netdata = var.enable_netdata }` +
  `enabled_features` / `enabled_exporters` local, and merge into **both** `templatefile()` calls.
- `cloud-init/{server,client}.yaml.tftpl` — add the canonical install block (these templates have no
  flag scaffolding today — add the `%{ if enable_netdata ~}` gating).
- `outputs.tf` — add `enabled_features` (so `conftest.py` can skip-not-fail) + optional `web_urls`
  with the two `:19999` URLs.

### Tests, docs, orchestration
- `clusters/<cluster>/tests/tofu/sizing_and_render.tftest.hcl` — hermetic `run` blocks (see Testing).
- `clusters/<cluster>/tests/testinfra/conftest.py` — netbox needs an `enabled_features` /
  `enable_netdata` session fixture added (logging/monitoring already expose the machinery).
- `clusters/centralized_{logging,monitoring}/docs/feature-flags.md` — document `enable_netdata`
  (flag-matrix row: default ✅, port 19999, role = all VMs).
- `Justfile` — generic `check`/`up`/`verify`/`recreate`/`open` need **no** edits (fully cluster-name
  generic). Optionally add a small `netdata-status CLUSTER` helper (SSH each VM, `systemctl is-active
  netdata`) in a trailing section, mirroring the Coroot `coroot-status`/`coroot-deploy` recipes.

### New Files
- `clusters/{centralized_logging,centralized_monitoring,centralized_netbox}/tests/testinfra/test_netdata.py`

## Implementation Phases

### Phase 1: Foundation
Add / confirm the `enable_netdata` flag and `local.flags` threading in all three clusters; bootstrap
the flag machinery into `centralized_netbox`.

### Phase 2: Core Implementation
Drop the canonical install block into all 7 VM templates; wire the flag-gated scrape into the two
Prometheus-bearing clusters; extend the `web_urls` / `enabled_features` outputs.

### Phase 3: Integration & Polish
Hermetic `run` blocks + live `test_netdata.py` per cluster; feature-flags docs; optional
`netdata-status` recipe.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Monitoring — generalize to the server VM
- Add the canonical install block to `server.yaml.tftpl`; replace the k0s one-liner with it.
- Extend the `netdata` scrape job with the server IP; add the server URL to `outputs.tf` `web_urls`.

### 2. Logging — add flag, install on 3 VMs, wire scrape
- Add `enable_netdata` var (default `true`) + the `local.flags` entry.
- Add the install block to all three templates.
- Add the `logging-netdata` job to the docker VM's inline Prometheus + the reference `logging-scrape.yml`.

### 3. Netbox — bootstrap flag + install on both VMs
- Add `enable_netdata` var, minimal `local.flags` / `enabled_features`, merge into both templatefiles.
- Add the install block to both templates; add `enabled_features` (+ optional `web_urls`) output.

### 4. Hermetic tests (all clusters)
- In each `sizing_and_render.tftest.hcl` add a `netdata_absent_when_disabled` run
  (`variables { enable_netdata = false }`, assert `!strcontains(..., "netdata")` across every VM's
  `local_file.*.content`, and netdata excluded from `enabled_*`) and a `netdata_renders_by_default`
  run asserting the install block **and** scrape job render, the telemetry opt-out is present, and
  `can(yamldecode(local_file.*.content))` still holds. Use the
  `alltrue([for c in [...] : strcontains(c, "...")])` idiom to assert across all VMs at once.

### 5. Live tests (all clusters)
- New `test_netdata.py` per cluster: a `require_netdata` skip fixture (reads `enabled_features` /
  `enabled_exporters`), then per-VM assert `host.service("netdata").is_running`, poll
  `host.socket("tcp://0.0.0.0:19999").is_listening`, and `curl -fsS
  localhost:19999/api/v1/allmetrics?format=prometheus` returns rc 0. Model on `test_coroot.py`
  (skip-on-flag + poll with a deadline for the slow kickstart first boot). On the two
  Prometheus-bearing clusters, additionally assert the `netdata` target is `up` via Prometheus
  `/api/v1/targets` (mirror `test_metrics.py`).

### 6. Docs
- Add the `enable_netdata` row + a short "Netdata (real-time agent, all VMs)" section to both
  `docs/feature-flags.md` files (mermaid / flag-matrix style already there).

### 7. Validate
- Run the Validation Commands below — hermetic for all three, then a live `recreate` + `verify` on
  at least one cluster.

## Testing Strategy

- **Hermetic (`just check <cluster>`)** — no VMs. Per cluster: (a) with `enable_netdata=false`, the
  kickstart command and the `netdata` scrape job are **absent** from every rendered `local_file` and
  the `enabled_*` outputs exclude netdata; (b) by default they **render** on every VM, the telemetry
  opt-out is present, and rendered cloud-init stays valid YAML (`can(yamldecode(...))`).
- **Live (`just verify <cluster>`)** — after `just recreate`. Skip-not-fail when the flag is off;
  otherwise per VM assert the `netdata` service is running/enabled, `:19999` listens, and the
  Prometheus endpoint returns metrics. On the two Prometheus-bearing clusters, also assert the
  `netdata` scrape target is `up`.
- **Edge cases:** first-boot race (kickstart is slow — poll with a deadline, never assume instant);
  arm64 native-package path (`--dont-wait` + `|| true` keep cloud-init from failing the boot);
  overlap with node_exporter / cAdvisor already on most VMs (intentional — Netdata adds per-second
  realtime + built-in dashboards; documented, not a conflict).

## Acceptance Criteria
- `enable_netdata` exists in all three clusters, default `true`, gating both install and (where a
  Prometheus exists) scrape.
- With defaults, all 7 VMs run Netdata on `:19999`; with `enable_netdata=false` a cluster renders
  without any netdata artifact (hermetic proof).
- Telemetry disabled and no Netdata Cloud claim on every install.
- `just check <cluster>` passes for all three; `test_netdata.py` passes live on at least one cluster.

## Validation Commands
- `just check centralized_logging && just check centralized_monitoring && just check centralized_netbox`
  — hermetic fmt/validate/test, all green.
- `tofu -chdir=clusters/centralized_netbox test -test-directory=tests/tofu` — run the new netbox hermetic block.
- `just recreate centralized_netbox && just verify centralized_netbox` — live: cloud-init redeploy +
  `test_netdata.py` asserts the agent on both VMs.
- `curl -fsS http://<vm_ip>:19999/api/v1/allmetrics?format=prometheus | head` — endpoint returns metrics.
- `tofu -chdir=clusters/centralized_logging apply -var enable_netdata=false` then
  `just check centralized_logging` — confirm opt-out renders no netdata.

## Notes
- **Editing cloud-init requires `just recreate`, not `just up`** — the provider keys the VM on the
  cloud-init file path, not its content, so a plain `up` reuses stale VMs and live tests then run
  against stale cloud-init (see CLAUDE.md / `specs/coroot.md`).
- No new host tooling / `uv add` needed; testinfra + tofu test are already wired per cluster.
- Netdata overlaps node_exporter / cAdvisor on most VMs (redundant host metrics) but is **net-new**
  on the two netbox VMs, which have zero observability today.
- **Future work (kept in mind, not built here):** the Netdata Grafana plugin as a monitoring-stack
  datasource; the systemd-journal-logs plugin; StatsD / OpenTelemetry ingestion; network-flows
  collector. Links in References below.

## References

Consult these for install flags, config options, and best practices:

- Product / overview — https://www.netdata.cloud/netdata/
- Repo getting-started — https://github.com/netdata/netdata#getting-started
- Repo how-it-works — https://github.com/netdata/netdata#how-it-works
- Repo FAQ — https://github.com/netdata/netdata#faq
- Repo documentation index — https://github.com/netdata/netdata#book-documentation
- **Install (kickstart.sh)** — https://learn.netdata.cloud/docs/netdata-agent/installation/linux
- **Disable anonymous telemetry** — https://learn.netdata.cloud/docs/netdata-agent/anonymous-telemetry-events
- Logging — https://learn.netdata.cloud/docs/netdata-agent/logging
- Collectors configuration — https://learn.netdata.cloud/docs/collecting-metrics/collectors-configuration
- Service discovery — https://learn.netdata.cloud/docs/collecting-metrics/service-discovery
- StatsD — https://learn.netdata.cloud/docs/collecting-metrics/statsd
- Containers & cgroups — https://learn.netdata.cloud/docs/collecting-metrics/containers-and-cgroups
- OpenTelemetry metrics — https://learn.netdata.cloud/docs/collecting-metrics/opentelemetry/opentelemetry-metrics
- Secrets management — https://learn.netdata.cloud/docs/collecting-metrics/secrets-management
- **Prometheus export** — https://learn.netdata.cloud/docs/exporting-metrics/prometheus
- Network flows install — https://learn.netdata.cloud/docs/network-performance-monitoring/network-flows/installation
- Syslog-from-network-devices (OTel collector) — https://learn.netdata.cloud/docs/network-performance-monitoring/syslog-from-network-devices/opentelemetry-collector-setup
- systemd-journal logs — https://learn.netdata.cloud/docs/logs/systemd-journal-logs
- systemd-journal plugin reference — https://learn.netdata.cloud/docs/logs/systemd-journal-logs/systemd-journal-plugin-reference
- Grafana plugin — https://learn.netdata.cloud/docs/dashboards-and-charts/grafana-plugin
- Maintenance / update — https://learn.netdata.cloud/docs/netdata-agent/maintenance/update
