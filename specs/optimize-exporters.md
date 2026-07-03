# Optimize & Expand `systemd_exporter` + `process-exporter` Across Clusters

## Context

Two exporters are already vendored as upstream Go source on this machine
(`/Users/malcolm/dev/systemd_exporter` @ `v0.7.0`+, `/Users/malcolm/dev/process-exporter` @ `v0.8.7`) —
both are **clean upstream checkouts, no local forks**. The lab does *not* build them from source;
it downloads pinned release tarballs at first boot via the shared
`/usr/local/sbin/install-exporter.sh` helper and runs them as systemd units.

Today these exporters run with **max-cost, max-cardinality defaults**:

- **process-exporter** uses a catch-all group config (`/etc/process-exporter/all.yaml`,
  `name: "{{.Comm}}"` matching `.+`) with the expensive defaults **on**: `-threads=true`
  (per-thread series), `-gather-smaps=true` (PSS reads), `-children=true`, `-remove-empty-groups=false`
  (dead ephemeral groups accumulate).
- **systemd_exporter** runs with only `--web.listen-address=:9558` — no unit filtering, so
  `unit-include=.+` scrapes **every** unit and emits 5 `systemd_unit_state` series per unit.

Coverage is also uneven, despite the branch name `feature-systemd-process-exporter`:

| Cluster | node_exporter | process-exporter | systemd_exporter |
|---|---|---|---|
| `centralized_logging` | ✅ 3 VMs | ✅ 3 VMs (catch-all) | ✅ 3 VMs (unfiltered) |
| `centralized_monitoring` | ✅ | ✅ k0s client (catch-all) | ❌ **missing** (dashboard `processes-systemd.json` exists but has no `systemd_*` source) |
| `centralized_pki` | ✅ ca+services | ❌ | ❌ |
| `centralized_netbox` | ❌ **none** | ❌ | ❌ |

**Goal:** (1) tune the existing deployments for low cardinality/CPU on small arm64 lab VMs,
(2) bump process-exporter `0.8.4 → 0.8.7`, and (3) roll both exporters out to every cluster —
adding systemd_exporter to monitoring, both to PKI, and both (plus bootstrapping the whole
exporter pattern incl. node_exporter) to NetBox. All tuning flags already exist in the pinned
versions, so this is chiefly a **configuration + coverage** change, not a version chase.

## Objective

When complete: every cluster deploys both exporters (NetBox also gains node_exporter), all
process-exporter instances run curated groups with `-threads=false -gather-smaps=false
-remove-empty-groups`, all systemd_exporter instances run a curated `--systemd.collector.unit-include`,
process-exporter is pinned to `v0.8.7`, and each cluster's hermetic + live test suites and
`web_urls` outputs cover the new/changed endpoints.

## Out of scope (do NOT touch)

- The three untracked `clusters/*/.cross-cluster.auto.tfvars.json` files (from another branch).
- Wiring `centralized_monitoring` to *scrape* PKI/NetBox cross-cluster — that's the cross-cluster
  branch's job. PKI/NetBox have no local Prometheus; their exporters bind `0.0.0.0` and are verified
  locally (curl over SSH) per the lab's "exporters present, pull deferred" convention. Their
  scraping is deferred.

## Solution Approach

Mirror the existing, well-established exporter pattern (documented by the codebase itself):
`variables.tf` bool → `local.flags` map → `templatefile()` → `%{ if enable_X ~}` cloud-init block
calling `install-exporter.sh <name> <url-with-{ARCH}> <bin> [args]` → `outputs.tf`
(`web_urls_metrics_candidates` + `metrics_targets`) → hermetic `*.tftest.hcl` assertion +
live `test_metrics.py` `(flag, role, port)` tuple. Reuse the `{ARCH}` placeholder mechanism in
`install-exporter.sh` for arm64. `centralized_logging` is the canonical working template for
systemd_exporter; copy from it.

### Shared version pins (apply everywhere)
- `systemd_exporter` → **v0.7.0** (already latest release; keep).
- `process-exporter` → **v0.8.7** (bump from v0.8.4). URL:
  `https://github.com/ncabatoff/process-exporter/releases/download/v0.8.7/process-exporter-0.8.7.linux-{ARCH}.tar.gz`

### Shared curated process-exporter config (`/etc/process-exporter/all.yaml`)
Replace the catch-all with: (a) named groups for apps that fan out into many workers/shims so they
aggregate, each with a cheap `comm`/`exe` clause; then (b) a **final `{{.Comm}}` catch-all** so the
long tail still gets one bounded group per distinct command (kept bounded by `-remove-empty-groups`).
Per-cluster group additions:
- **logging**: `syslog-ng`, container-runtime (`dockerd|containerd|containerd-shim`), `kube`/`k0s`, exporters.
- **monitoring**: container-runtime, `prometheus|grafana|alertmanager|otelcol`, `kube`/`k0s`.
- **pki**: `step-ca`, container-runtime (traefik/authelia compose), exporters.
- **netbox**: `netbox` (gunicorn + rq workers), container-runtime, `postgres|redis|caddy`.

Example structure (tailor `name`/selectors per cluster):
```yaml
process_names:
  - name: netbox
    exe: [ gunicorn, python3 ]
    cmdline: [ 'netbox' ]
  - name: container-runtime
    comm: [ dockerd, containerd, containerd-shim-runc-v2 ]
  - name: "{{.Comm}}"        # bounded fallback; empty groups pruned at runtime
    cmdline: [ '.+' ]
```
process-exporter run args everywhere: `--config.path=/etc/process-exporter/all.yaml -threads=false -gather-smaps=false -remove-empty-groups`.

### Shared curated systemd_exporter args
`--web.listen-address=:9558 --systemd.collector.unit-include='<curated regex>'` where the regex
scopes to the units that matter per cluster, e.g.
`'(sshd|docker|containerd|node_exporter|systemd_exporter|process-exporter|<app-units>)\.service'`.
Keep the default device exclude. (Optionally add `--systemd.collector.enable-restart-count` for
restart alerting — cheap, valuable; decide per cluster.)

## Relevant Files

Canonical template / reference:
- `clusters/centralized_logging/cloud-init/{central,docker-client,k0s-client}.yaml.tftpl` — the
  `%{ if enable_process_exporter ~}` / `enable_systemd_exporter` config + install blocks to edit and copy.
- `clusters/centralized_logging/{variables.tf,main.tf,outputs.tf}` — flag → `local.flags` → outputs pattern.
- `clusters/centralized_logging/tests/tofu/sizing_and_render.tftest.hcl` — hermetic render assertions.
- `clusters/centralized_logging/tests/testinfra/test_metrics.py` — `FLAG_ENDPOINTS` live checks.

Monitoring (add systemd_exporter; tune process-exporter):
- `clusters/centralized_monitoring/cloud-init/k0s-client.yaml.tftpl` (process config ~L68-70, process install ~L162-164) — tune + add systemd install.
- `clusters/centralized_monitoring/cloud-init/prometheus/prometheus.yml.tftpl` (~L33-37) — add a `systemd` scrape job (`${k0s_ip}:9558`) next to `process`.
- `clusters/centralized_monitoring/{variables.tf,main.tf,outputs.tf}` — add `enable_systemd_exporter` (default true), thread into `local.flags`, add `:9558` to metrics outputs.
- `clusters/centralized_monitoring/tests/tofu/sizing_and_render.tftest.hcl` + `tests/testinfra/test_k0s_client.py` — add systemd assertions/tuple.
- `clusters/centralized_monitoring/scripts/prometheus_cli.py` — map `enable_systemd_exporter` → `systemd` job (mirror the `process` mapping).

PKI (add both exporters — helper already present):
- `clusters/centralized_pki/cloud-init/{ca,services}.yaml.tftpl` — add process config `write_files` + gated install lines for both exporters after the node_exporter block (`ca` ~L82, `services` ~L182).
- `clusters/centralized_pki/{variables.tf,main.tf}` — add `enable_process_exporter` + `enable_systemd_exporter` flags.
- `clusters/centralized_pki/outputs.tf` (~L62-66) — add `:9256`/`:9558` `web_urls_metrics_candidates`.
- `clusters/centralized_pki/tests/{tofu,testinfra}/` — render assertions + a `test_metrics.py`.

NetBox (bootstrap the whole exporter pattern):
- `clusters/centralized_netbox/cloud-init/{server,client}.yaml.tftpl` — add the `install-exporter.sh` helper (`write_files`, copy verbatim from a logging template), plus node_exporter + process-exporter + systemd_exporter install blocks in `runcmd` (`server` ~L247, `client` ~L122), and the process config `write_files`.
- `clusters/centralized_netbox/{variables.tf,main.tf}` — add `enable_node_exporter` + `enable_process_exporter` + `enable_systemd_exporter` flags, thread into both `templatefile()` calls via a new `local.flags` map.
- `clusters/centralized_netbox/outputs.tf` — add the `web_urls` (`core`/`all`) + `web_urls_metrics_candidates` pattern (copy the shape from PKI `outputs.tf`).
- `clusters/centralized_netbox/tests/{tofu,testinfra}/` — add render assertions + a new `test_metrics.py`.

Shared:
- `clusters/centralized_logging/docs/feature-flags.md` — update the flag matrix.
- Grafana `Instances/processes-systemd.json` (logging + monitoring) — optional `systemd_unit_state` panels.

### New Files
- `clusters/centralized_pki/tests/testinfra/test_metrics.py`
- `clusters/centralized_netbox/tests/testinfra/test_metrics.py`

## Step by Step Tasks

1. **Save the spec** — this file.
2. **Bump process-exporter to v0.8.7** in all existing install lines (logging ×3, monitoring k0s).
3. **Tune process-exporter** — curated `all.yaml` + `-threads=false -gather-smaps=false -remove-empty-groups` (logging ×3, monitoring).
4. **Tune systemd_exporter** — curated `--systemd.collector.unit-include` (logging ×3).
5. **Add systemd_exporter to monitoring** — var/flag, k0s install line, `systemd` scrape job, outputs, prometheus_cli mapping.
6. **Add both exporters to PKI** — flags, install lines + process config on ca+services, outputs.
7. **Bootstrap exporters in NetBox** — helper + node_exporter + both exporters, flags/local.flags, web_urls output.
8. **Update tests** — hermetic render assertions + live `test_metrics.py` tuples (new files for PKI, NetBox).
9. **Docs** — feature-flags matrix; optional dashboard panels.
10. **Validate** — `just check` all four; live `just recreate` + `just verify` on at least one cluster.

## Testing Strategy

- **Hermetic (`just check <cluster>`):** `strcontains` assertions on rendered cloud-init prove the
  version bump, curated config, perf flags, and unit-include render; negative `!strcontains` cases
  for disabled flags. No VMs.
- **Live (`just verify <cluster>`):** testinfra curls `http://localhost:<port>/metrics` per role,
  auto-skipping any flag absent from `enabled_exporters`. For monitoring, assert `systemd`/`process`
  Prometheus targets are `up`.
- **Edge cases:** cloud-init edits require `just recreate` (not `just up`); NetBox stack comes up
  asynchronously so exporter installs must not depend on the netbox oneshot.

## Acceptance Criteria

- `process-exporter` is `v0.8.7` everywhere; runs curated `all.yaml` + `-threads=false -gather-smaps=false -remove-empty-groups`.
- `systemd_exporter` runs a curated `--systemd.collector.unit-include` on logging, monitoring, PKI, NetBox; monitoring has a `systemd` scrape job → `<k0s_ip>:9558`.
- Coverage: logging (both, tuned), monitoring (both — systemd added), PKI (both added), NetBox (node_exporter + both, pattern bootstrapped incl. `web_urls`).
- `web_urls`/`metrics_targets` expose `:9256`/`:9558` (and `:9100` for NetBox); `just open --full` opens them.
- `just check` passes for all four clusters.
- The three `.cross-cluster.auto.tfvars.json` files remain untouched/uncommitted.

## Validation Commands

- `just check centralized_logging && just check centralized_monitoring && just check centralized_pki && just check centralized_netbox`
- `tofu -chdir=clusters/centralized_monitoring test -test-directory=tests/tofu`
- `just recreate centralized_monitoring && just verify centralized_monitoring`
- `just verify-api centralized_monitoring`
- `git status --porcelain` — confirm the three `.cross-cluster.auto.tfvars.json` files remain untracked.

## Notes

- Both exporters ship arm64 release tarballs; the `{ARCH}` placeholder in `install-exporter.sh`
  (`aarch64→arm64`) handles Apple-Silicon Multipass VMs (unlike the amd64-only `journald-exporter`).
- systemd_exporter is installed as a **host binary** (needs host D-Bus/systemd + `/proc`), so on
  monitoring it goes on the **k0s client**, not the compose-based server.
- No new dependencies, no source builds — the local source repos are the reference for flags/versions only.
- `just recreate` (not `just up`) is required after these cloud-init edits.
