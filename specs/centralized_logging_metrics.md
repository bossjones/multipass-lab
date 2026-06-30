# Centralized Logging — Metrics & Exporter Layer

> Adds a Prometheus **exporter layer** to the `centralized_logging` cluster. This spec only
> makes the metrics *available* (exporters installed, `/metrics` endpoints exposed and bound to
> `0.0.0.0`). It deliberately does **not** wire a scrape — the plan is to later point the separate
> `centralized_monitoring` cluster's Prometheus at these endpoints. The scrape config and alert
> rules below are shipped as **paste-in artifacts** for that future integration.

- **Cluster:** `clusters/centralized_logging/` (VMs: `central`, `k0s`, `docker`)
- **Companion specs:** [`centralized_logging.md`](./centralized_logging.md) (the cluster this extends),
  [`centralized_monitoring.md`](./centralized_monitoring.md) + [`e2e-centralized-monitoring.md`](./e2e-centralized-monitoring.md)
  (the exporter catalog, ports, and arm64 fixes this spec reuses).

---

## 1. Purpose & scope

The logging cluster ships logs (syslog-ng push: clients → `central:514`) but emits **no metrics**.
This spec installs exporters on all three VMs so their health and the log pipeline itself become
observable in Prometheus. Scope boundaries:

- **In scope:** exporter install (cloud-init), feature flags, endpoint inventory, a `metrics_targets`
  output for discovery, future-integration scrape config + alert rules, and the hermetic+live test plan.
- **Out of scope (deferred):** changing the `docker` VM's on-box Prometheus (`/opt/stack/prometheus.yml`)
  to scrape these exporters. That Prometheus keeps its current two jobs. The future
  `centralized_monitoring` Prometheus will own the cross-cluster scrape.

The monitoring cluster already solved every hard problem here (arm64 binaries, systemd-unit wrapping,
cAdvisor port conflict, kube-state-metrics on single-node k0s). This spec **mirrors that framework**
rather than inventing a new one.

---

## 2. Live findings (verified this session)

Probed over direct SSH to the running VMs (`multipass exec` was failing with a daemon networking
quirk, but port 22 is open — the same SSH path testinfra uses):

| Fact | Detail | Consequence |
|---|---|---|
| Architecture | All 3 VMs Ubuntu 24.04, **aarch64 (arm64)** | every binary URL needs `{ARCH}` substitution |
| syslog-ng | `4.3.1` on all 3 VMs | native Prometheus stats available (below) |
| **syslog-ng native metrics** | `syslog-ng-ctl stats prometheus` already emits Prometheus text (`syslogng_input_events_total`, `syslogng_socket_connections`, `syslogng_internal_events_total{result="dropped"}`, …) | **no third-party syslog-ng exporter needed** |
| `central` | syslog-ng :514; no exporters | gets node + syslog-ng textfile + systemd + journald + process + filestat |
| `docker` | Compose project `stack` at `/opt/stack/`: Prometheus :9090, Grafana :3000, Alertmanager :9093, Traefik :80/**:8080**, Heimdall; `prometheus.yml` scrapes only `localhost:9090` + `traefik:8080`; Traefik metrics off | **:8080 taken by Traefik → cAdvisor must use :8089** |
| `k0s` | kube-proxy metrics live on :10249; kubelet :10250 + read-only :10255 cadvisor reachable; no kube-state-metrics | reuse monitoring's `--read-only-port=10255` + kube-state-metrics manifest |

---

## 3. Architecture decision — "exporters present, pull deferred"

```
        ┌──────────────────────────── future ────────────────────────────┐
        │            centralized_monitoring Prometheus                    │
        │                 (paste in §9 scrape config)                     │
        └───────▲───────────────────▲────────────────────────▲───────────┘
                │ pull              │ pull                    │ pull
   central:9100/9558/12345/9256/9943   docker:9100/8089/8082/…   k0s:9100/8089/10249/8081/…
        │                            │                          │
   ┌────┴────┐                  ┌────┴────┐                ┌────┴────┐
   │ central │                  │ docker  │                │  k0s    │
   │syslog-ng│◀── logs ── push ─│ shipper │   push ──────▶ │ shipper │
   │ server  │                  └─────────┘                └─────────┘
   └─────────┘
```

- **Logging pushes; Prometheus pulls.** This spec only stands up the pull *targets*. No scrape is
  wired yet, so there is **no dependency cycle** and **no peer-IP injection** needed for the metrics
  layer (the existing log-shipping IP injection of `central_ip` is untouched).
- **All exporter listeners bind `0.0.0.0`** so a future cross-VM/cross-cluster scrape works with no
  rebind. (node_exporter, cadvisor, etc. default to all-interfaces; journald-exporter and
  systemd_exporter take an explicit `--web.listen-address=:PORT`.)
- **Install-only feature gating.** Each exporter is gated on its own `enable_*` flag in cloud-init.
  Unlike the monitoring cluster (which also gates `prometheus.yml` jobs), here the flag only controls
  *install* — there is no local job to gate.

---

## 4. syslog-ng metrics design (chosen: node_exporter textfile collector)

syslog-ng 4.1+ exposes a Prometheus-formatted stats dump via `syslog-ng-ctl stats prometheus`
(confirmed on our 4.3.1). The chosen integration is the **node_exporter textfile collector**: a
systemd timer periodically writes that dump to a `.prom` file, and node_exporter serves it on its
existing `:9100`. This means **one port, one binary, no extra service** carries both host metrics and
syslog-ng metrics on every VM.

```
# /usr/local/sbin/syslogng-textfile.sh  (write_files, 0755)
#!/usr/bin/env bash
set -euo pipefail
out=/var/lib/node_exporter/textfile_collector/syslogng.prom
tmp="$(mktemp)"
/usr/sbin/syslog-ng-ctl stats prometheus > "$tmp" 2>/dev/null || true
mv "$tmp" "$out"
```

node_exporter is launched with `--collector.textfile.directory=/var/lib/node_exporter/textfile_collector`
(in addition to the monitoring cluster's `--collector.systemd`). A `.timer` runs the script every 15s.

### Rejected alternatives (documented for the future)

| Option | Why not (for this lab) |
|---|---|
| **Native `stats-exporter()` source** — syslog-ng serves its own HTTP `/metrics` ([docs](https://syslog-ng.github.io/admin-guide/060_Sources/153_stats_exporter/README)) | Cleanest in principle, but adds a syslog-ng config block + a dedicated port to firewall, and availability of the `stats-exporter` source driver in the stock 4.3.1 apt build is unconfirmed. The textfile path is guaranteed to work and reuses node_exporter. |
| **czanik/sngexporter** (Python HTTP wrapper) ([repo](https://github.com/czanik/sngexporter)) | Standalone service + Python runtime + its own port; it ultimately just calls `STATS PROMETHEUS` over the control socket — the same data the textfile path captures with no daemon. |
| **axoflow/axosyslog-metrics-exporter** (Go, arm64) ([repo](https://github.com/axoflow/axosyslog-metrics-exporter)) | Works with stock syslog-ng 4.1+, but again a separate binary/port for data we already get for free. Keep as a future swap-in if a dedicated `:PORT` is preferred over textfile. |

---

## 5. Exporter inventory (per VM, all arm64, bound `0.0.0.0`)

| Exporter | central | docker | k0s | Port | Flag | Default | Notes |
|---|:--:|:--:|:--:|---|---|:--:|---|
| node_exporter | ✓ | ✓ | ✓ | 9100 | `enable_node_exporter` | on | `--collector.systemd --collector.textfile.directory=…`; also serves syslog-ng `.prom` |
| syslog-ng metrics (textfile) | ✓ | ✓ | ✓ | via 9100 | `enable_syslogng_metrics` | on | timer → `syslog-ng-ctl stats prometheus` |
| systemd_exporter | ✓ | ✓ | ✓ | 9558 | `enable_systemd_exporter` | on | richer per-unit health than node_exporter's systemd collector; watch `syslog-ng.service` |
| journald-exporter | ✓ | ✓ | ✓ | 12345 | `enable_journald_exporter` | on | dead-claudia, Rust, `GET /metrics`; **arm64 asset risk — see §13** |
| process-exporter | ✓ | ✓ | ✓ | 9256 | `enable_process_exporter` | on | catch-all `all.yaml` (reuse monitoring); watches `syslog-ng`/`dockerd`/`k0s` |
| filestat_exporter | ✓ | — | — | 9943 | `enable_filestat_exporter` | on | watches `/var/log/remote/*` — received-log size/mtime (detect a client that stopped shipping) |
| cAdvisor | — | ✓ | ✓ | 8089 | `enable_cadvisor` | on | **:8080 taken** by Traefik (docker) / kube-router (k0s) |
| Traefik metrics | — | ✓ | — | 8082 | `enable_traefik_metrics` | on | edit `/opt/stack/compose.yaml` to add `--metrics.prometheus` + `:8082` entrypoint |
| k0s kube metrics | — | — | ✓ | 10249 / 10255 | `enable_kube_metrics` | on | kube-proxy `:10249/metrics`; kubelet read-only `:10255/metrics/cadvisor` |
| kube-state-metrics | — | — | ✓ | 8081 | `enable_kube_state_metrics` | on | hostNetwork Deployment; reuse monitoring's `deployment.yaml` verbatim |

**Per-VM rationale.** `central` is the log sink, so it gets the log-pipeline exporters (syslog-ng
stats + filestat over `/var/log/remote`) plus the OS/systemd/journald/process baseline. `docker` adds
container visibility (cAdvisor) and the Traefik metrics it already could emit. `k0s` adds the k8s-node
layer (kubelet/kube-proxy/kube-state-metrics) on top of the OS baseline. filestat lives on `central`
only because `/var/log/remote/*` exists only there.

---

## 6. Feature flags (`variables.tf`)

Add one boolean per exporter plus optional port overrides. Defaults follow §5 (core + the four
optional exporters ON; the lab is small enough to run the full set). Example shape, matching the
cluster's existing variable style:

```hcl
variable "enable_node_exporter"     { type = bool, default = true }
variable "enable_syslogng_metrics"  { type = bool, default = true }
variable "enable_systemd_exporter"  { type = bool, default = true }
variable "enable_journald_exporter" { type = bool, default = true }   # see §13 arm64 risk
variable "enable_process_exporter"  { type = bool, default = true }
variable "enable_filestat_exporter" { type = bool, default = true }   # central only
variable "enable_cadvisor"          { type = bool, default = true }   # docker + k0s, :8089
variable "enable_traefik_metrics"   { type = bool, default = true }   # docker only, :8082
variable "enable_kube_metrics"      { type = bool, default = true }   # k0s only
variable "enable_kube_state_metrics"{ type = bool, default = true }   # k0s only, :8081
```

Each flag is threaded into the relevant `templatefile(...)` call in `main.tf` (same way
`server_conf`/`client_conf` are threaded today), so cloud-init renders the install block only when the
flag is on. A disabled flag = the exporter is **neither installed nor running**.

---

## 7. Cloud-init changes per VM

Vendor the monitoring cluster's inline **`install-exporter.sh`** into all three logging cloud-init
templates (it is a `write_files` block, not a standalone repo file). It downloads a GitHub release
(tar.gz or raw binary), drops the binary in `/usr/local/bin`, and writes + enables a systemd unit;
`{ARCH}` in the URL is replaced with the Debian arch (`arm64`/`amd64`). Copy it verbatim — it is the
shared install primitive every block below calls.

### 7.1 `central.yaml.tftpl`
Currently installs only syslog-ng + the server config. Add (all flag-gated `%{ if … ~}`):
- `install-exporter.sh` (+ `mkdir -p /var/lib/node_exporter/textfile_collector`).
- **node_exporter** `:9100` — `node_exporter-1.8.2.linux-{ARCH}.tar.gz`, args
  `--collector.systemd --collector.textfile.directory=/var/lib/node_exporter/textfile_collector`.
- **syslog-ng textfile** — write `syslogng-textfile.sh` (§4) + a `.service`/`.timer` (15s), enable the timer.
- **systemd_exporter** `:9558` — `prometheus-community/systemd_exporter` release, `--web.listen-address=:9558`.
- **journald-exporter** `:12345` — see §13 for the arm64 install approach.
- **process-exporter** `:9256` — reuse `/etc/process-exporter/all.yaml` catch-all, `--config.path=…`.
- **filestat_exporter** `:9943` — config watching `/var/log/remote/*` (and `/etc/hostname` as a
  guaranteed-present file), `--config.file=/etc/filestat_exporter/filestat.yaml`.

### 7.2 `k0s-client.yaml.tftpl`
Add the core set (node + syslog-ng textfile + systemd + journald + process) **minus filestat**, plus:
- **cAdvisor** `:8089` — `cadvisor-v0.49.1-linux-{ARCH}`, `--port=8089` (`:8080` is kube-router).
- **k0s kube metrics** — install k0s with `--kubelet-extra-args="--read-only-port=10255"` (currently
  it installs plain `--single`); kube-proxy `:10249` and kubelet `:10255/metrics/cadvisor` then expose
  with no token.
- **kube-state-metrics** `:8081` — drop monitoring's `deployment.yaml` (hostNetwork, kubeconfig from
  `k0s kubeconfig admin`) and `k0s kubectl apply` after `/readyz`.

### 7.3 `docker-client.yaml.tftpl`
Add the core set **minus filestat/k0s**, plus:
- **cAdvisor** `:8089` (`:8080` is the Traefik dashboard).
- **Traefik metrics** `:8082` — extend `/opt/stack/compose.yaml` (rendered from `cloud-init/compose.yaml.tftpl`)
  with `--metrics.prometheus=true`, `--entrypoints.metrics.address=:8082`, and publish `8082:8082`.

---

## 8. Reused assets from the monitoring cluster

Copy these verbatim / lightly adapted (clusters are independently vendored, so duplication is correct):

- **`install-exporter.sh`** — inline `write_files` block in
  `clusters/centralized_monitoring/cloud-init/k0s-client.yaml.tftpl` (the `{ARCH}` + systemd-unit installer).
- **process-exporter `all.yaml`** — the `{{.Comm}}` catch-all group.
- **filestat `filestat.yaml`** — the `exporter.files.patterns` shape (point it at `/var/log/remote/*`).
- **kube-state-metrics `deployment.yaml`** — the hostNetwork Deployment with `--kubeconfig=/etc/ksm/kubeconfig`.
- The **node_exporter / cadvisor / process-exporter** release URLs + versions already pinned there
  (node_exporter 1.8.2, cadvisor 0.49.1, process-exporter 0.8.4, filestat 0.4.5).

New (not in monitoring): the **syslog-ng textfile** script+timer, **systemd_exporter**, and
**journald-exporter** install blocks.

---

## 9. Future monitoring integration (paste-in artifacts)

Ship these in `clusters/centralized_logging/cloud-init/prometheus/` as **reference files** (not wired
into any running Prometheus by this spec). The future `centralized_monitoring` Prometheus reads the
`metrics_targets` output (§10) to fill in IPs, then pastes these jobs.

```yaml
# logging-scrape.yml — add under scrape_configs of the monitoring Prometheus.
# Replace <central_ip>/<docker_ip>/<k0s_ip> from `tofu output -json metrics_targets`.
- job_name: logging-node        # host + syslog-ng textfile metrics
  static_configs: [{ targets: ["<central_ip>:9100","<docker_ip>:9100","<k0s_ip>:9100"] }]
- job_name: logging-systemd
  static_configs: [{ targets: ["<central_ip>:9558","<docker_ip>:9558","<k0s_ip>:9558"] }]
- job_name: logging-journald
  static_configs: [{ targets: ["<central_ip>:12345","<docker_ip>:12345","<k0s_ip>:12345"] }]
- job_name: logging-process
  static_configs: [{ targets: ["<central_ip>:9256","<docker_ip>:9256","<k0s_ip>:9256"] }]
- job_name: logging-filestat
  static_configs: [{ targets: ["<central_ip>:9943"] }]
- job_name: logging-cadvisor
  static_configs: [{ targets: ["<docker_ip>:8089","<k0s_ip>:8089"] }]
- job_name: logging-traefik
  static_configs: [{ targets: ["<docker_ip>:8082"] }]
- job_name: logging-kube
  static_configs: [{ targets: ["<k0s_ip>:10249","<k0s_ip>:8081"] }]
- job_name: logging-kubelet-cadvisor
  metrics_path: /metrics/cadvisor
  static_configs: [{ targets: ["<k0s_ip>:10255"] }]
```

---

## 10. Outputs (`outputs.tf`)

Add discovery outputs alongside the existing `hosts` output:

```hcl
output "enabled_exporters" {            # sorted list of enabled enable_* flags
  value = sort([for k, v in {
    node = var.enable_node_exporter, systemd = var.enable_systemd_exporter,
    journald = var.enable_journald_exporter, process = var.enable_process_exporter,
    filestat = var.enable_filestat_exporter, cadvisor = var.enable_cadvisor,
    traefik = var.enable_traefik_metrics, kube = var.enable_kube_metrics,
    kube_state = var.enable_kube_state_metrics,
  } : k if v])
}

output "metrics_targets" {              # role -> { ip, exporters: {name: port} }
  value = {
    central = { ip = multipass_instance.central.ipv4, exporters = { node=9100, systemd=9558, journald=12345, process=9256, filestat=9943 } }
    docker  = { ip = multipass_instance.docker.ipv4,  exporters = { node=9100, systemd=9558, journald=12345, process=9256, cadvisor=8089, traefik=8082 } }
    k0s     = { ip = multipass_instance.k0s.ipv4,     exporters = { node=9100, systemd=9558, journald=12345, process=9256, cadvisor=8089, kube_proxy=10249, kubelet=10255, kube_state=8081 } }
  }
}
```

`tests/testinfra/conftest.py` gains `metrics_targets` / `enabled_exporters` fixtures (mirrors the
monitoring cluster's conftest).

---

## 11. Alert rules (`prometheus/alert.rules.yml`, future-integration artifact)

Shipped for the future scraping Prometheus. Key rules (PromQL sketch):

| Alert | Condition |
|---|---|
| `SyslogNgServiceDown` | `node_systemd_unit_state{name="syslog-ng.service",state="active"} == 0` (or systemd_exporter equivalent) |
| `LoggingCentralUnreachable` | `up{job="logging-node", instance=~"<central_ip>.*"} == 0` |
| `SyslogNgEventsDropped` | `rate(syslogng_internal_events_total{result="dropped"}[5m]) > 0` |
| `SyslogNgDiskBufferGrowing` | client-side disk-buffer gauge trending up over 15m (syslog-ng `syslogng_*disk_*` series) |
| `NoLogsReceivedFromClient` | `time() - filestat_file_mtime_seconds{path=~"/var/log/remote/.*"} > 600` |
| `ExporterDown` | `up == 0` for any `logging-*` job |

---

## 12. Testing strategy (two-layer, per cluster convention)

**Hermetic** — `tests/tofu/*.tftest.hcl` (`mock_provider "multipass"`, `command = plan`):
- For each exporter, assert its install marker renders into the **right VM's** cloud-init when the flag
  is on (e.g. `central_ci.content` contains `node_exporter-1.8.2`, `syslogng-textfile.sh`, `:9558`).
- Assert it is **absent** when the flag is off (flip a flag in a `variables {}` block, assert no match).
- Assert cAdvisor renders **`--port=8089`** (not 8080) on docker + k0s.
- Assert filestat renders only on `central` and points at `/var/log/remote`.
- Assert k0s renders `--read-only-port=10255`.

**Live** — `tests/testinfra/` (SSH against running VMs, parametrized over `enabled_exporters`, skip
when off):
- Each exporter port is listening; `GET http://localhost:<port>/metrics` returns **200**.
- `/var/lib/node_exporter/textfile_collector/syslogng.prom` exists and contains `syslogng_`.
- systemd_exporter output contains the `syslog-ng.service` unit; filestat output contains a
  `/var/log/remote` path; k0s kube-proxy `:10249/metrics` and kubelet `:10255/metrics/cadvisor` return data.
- **Cross-VM reachability:** from a peer VM, `curl <central_ip>:9100/metrics` succeeds (confirms the
  `0.0.0.0` bind — the precondition for the future scrape).

Because nothing scrapes locally, the "is it up" check is per-endpoint `curl`, not a
Prometheus-targets-`up` assertion.

---

## 13. Risks & open questions

- **journald-exporter arm64 (highest risk).** dead-claudia/journald-exporter is Rust and may not
  publish a prebuilt `arm64` release asset ([repo](https://github.com/dead-claudia/journald-exporter),
  default port **12345**, `GET /metrics`). Mitigations, in order: (1) use a prebuilt arm64 asset if one
  exists; (2) `cargo build --release` in cloud-init (adds rust toolchain + build time); (3) leave
  `enable_journald_exporter=false`. syslog-ng textfile metrics + systemd_exporter already cover most
  log-pipeline health, so journald-exporter is the lowest-priority of the four optional exporters.
- **systemd metrics overlap.** node_exporter already runs `--collector.systemd`; systemd_exporter is
  additive (richer per-unit resource metrics). Keep both, or drop systemd_exporter if node_exporter's
  systemd collector suffices.
- **kube-state-metrics load** on single-node k0s (2 vCPU / 2G) — keep flag-gated; first thing to
  disable if the k0s VM is starved.
- **Firewall/binding.** Exporters are unauthenticated lab endpoints on the private multipass subnet.
  No `ufw` is configured today; if one is added later, open the §5 ports.
- **No secrets.** Nothing here reads `.env` or needs credentials.

---

## 14. Acceptance criteria

- All §5 exporters install via flag-gated cloud-init and expose `/metrics` (verified by live tests).
- Every endpoint binds `0.0.0.0` and is discoverable via the `metrics_targets` output.
- arm64 `{ARCH}` substitution and the `:8080→:8089` cAdvisor conflict are handled.
- `logging-scrape.yml` + `alert.rules.yml` exist as paste-in artifacts; the on-box Prometheus is unchanged.
- Hermetic tests assert per-flag render/absence; live tests assert endpoints + cross-VM reachability.

## 15. Validation commands

```sh
# hermetic (no VMs)
just check centralized_logging
# live (running VMs)
just up centralized_logging && just verify centralized_logging
# spot-check an endpoint binds for remote scrape
multipass exec centralized-logging-k0s -- curl -s "http://$(multipass info centralized-logging-central --format json | jq -r '.info."centralized-logging-central".ipv4[0]'):9100/metrics" | head
```

---

### Sources
- syslog-ng `stats-exporter` source: https://syslog-ng.github.io/admin-guide/060_Sources/153_stats_exporter/README
- czanik/sngexporter: https://github.com/czanik/sngexporter · blog: https://www.syslog-ng.com/community/b/blog/posts/syslog-ng-prometheus-exporter
- axoflow exporter: https://github.com/axoflow/axosyslog-metrics-exporter · blog: https://axoflow.com/blog/how-to-collect-axosyslog-metrics-into-prometheus
- prometheus-community/systemd_exporter: https://github.com/prometheus-community/systemd_exporter
- dead-claudia/journald-exporter: https://github.com/dead-claudia/journald-exporter
