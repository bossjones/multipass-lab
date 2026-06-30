# Spec: Centralized Monitoring Cluster

## Context

`multipass-lab` prototypes homelab infrastructure with OpenTofu + Multipass before promoting
it to Proxmox. This is the **second cluster** — a sibling to `centralized_logging` that does
for *metrics, traces, and uptime* what the logging cluster does for *logs*: stand up one
observability **server** that watches a fully-instrumented host, so the same modules can later
target a real Proxmox VM. It is an MVP built around **Prometheus** (pull-based metrics) with
**OpenObserve** as the OTLP backend for traces/logs, chosen deliberately because OpenObserve
also ingests RFC5424 syslog — so `centralized_logging` can eventually ship into the same sink.

One structural inversion vs logging is worth stating up front: **logging pushes (clients →
central); Prometheus pulls (server → client)**. So the runtime IP-injection edge flips — the
monitored host is created **first**, and the server's `prometheus.yml` is rendered from *its*
IP (logging renders the clients from the central IP).

Each cluster is **vendored to its own folder** (`clusters/centralized_monitoring/`). One
`tofu apply` brings up two Multipass VMs; the root `Justfile` orchestrates by cluster name.

## Objective

`just up centralized_monitoring` provisions 2 Multipass VMs via OpenTofu:

1. **server** — the observability hub. A single Docker Compose stack: **Prometheus**,
   **Alertmanager**, **Grafana**, **OpenObserve**, **OpenTelemetry Collector**, **Heimdall**,
   **Uptime Kuma**, **blackbox_exporter**, plus its own node_exporter/cAdvisor for self-metrics.
2. **k0s-client** — the monitored host: single-node k0s **plus** the full Linux exporter bundle.
   Because it is itself an Ubuntu host running k0s, the server scrapes it at **two layers** —
   the OS (node_exporter, process-exporter, systemd, netdata) *and* the k8s node
   (kube-state-metrics, kubelet/cAdvisor). Anything monitorable is monitored.

The server pulls every reachable target on a fixed interval; Grafana renders Prometheus +
OpenObserve; Uptime Kuma and blackbox_exporter watch endpoint health.

Every exporter and optional integration is **feature-flagged** with an individual `enable_*`
boolean, and features are organized into three tiers — **MVP**, **Reach**, and
**Nice-to-have**. Defaults ship **MVP + Reach ON, Nice-to-have OFF** (see *Feature tiers &
flags* below). The core Prometheus/Grafana/Alertmanager spine is always on.

## Architecture

```
        ┌──────────────────────────────┐  node_exporter :9100  ─┐
        │ centralized-monitoring-k0s   │  cadvisor      :8080   │
        │  k0s --single                │  process-exp   :9256   │  Prometheus
        │  + full exporter bundle      │  netdata       :19999  │  scrape (pull)
        └──────────────────────────────┘  kube-state-metrics    │  HTTP /metrics
                                           kubelet/cAdvisor     ◀┘
                                                        ▲
        ┌──────────────────────────────────────────────┴───────────────┐
        │ centralized-monitoring-server                                 │
        │  docker compose: prometheus :9090 · alertmanager :9093        │
        │  grafana :3000 · openobserve :5080 · otel-collector :4317/18  │
        │  uptime-kuma :3001 · heimdall :80 · blackbox :9115            │
        └───────────────────────────────────────────────────────────────┘
                                          (future: centralized_logging ─▶ OpenObserve)
```

The diagram shows the always-on MVP services. Reach/Nice features (Traefik ingress, Vector,
and the nut/statsd/ssh/nftables/filestat/osquery/eBPF/ffmpeg/script exporters) attach via
their `enable_*` flags — see *Feature tiers & flags*.

### Resource sizing

| VM | vCPU | RAM | Disk | Why |
|----|------|-----|------|-----|
| server | 4 | 8G | **40G** | Prometheus TSDB + Grafana + OpenObserve + OTel + Kuma + Heimdall + blackbox |
| k0s-client | 2 | 4G | 30G | single-node k0s + node/cadvisor/process/systemd/netdata exporters |
| **total** | **6** | **12G** | **70G** | comfortable on a 24G+ host (works on 16G, tight) |

### Provider & IP injection (flipped vs logging)

- Provider: [`larstobi/multipass`](https://registry.terraform.io/providers/larstobi/multipass)
  (`~> 1.4`, public registry — `tofu init` fetches it) + `hashicorp/local ~> 2.4`;
  `required_version >= 1.7`. `multipass_instance` exposes `name`, `image`, `cpus`, `memory`,
  `disk`, `cloudinit_file` (a **file path**), and a computed `ipv4`. No bridged networking —
  VMs reach each other on the Multipass subnet by IP.
- Multipass hands out DHCP IPs, so the scrape target IP can't be hardcoded. Because Prometheus
  **pulls**, the dependency edge runs opposite to logging. OpenTofu:
  1. creates **`k0s-client` first**,
  2. reads its computed `ipv4`,
  3. renders the server's `prometheus.yml` from a `templatefile()` (the client IP becomes a
     scrape target) into a `local_file`,
  4. points the server `multipass_instance.cloudinit_file` at the rendered cloud-init that
     embeds that `prometheus.yml`.

  The implicit dependency graph (`server → local_file(prometheus.yml) → k0s.ipv4 → k0s
  instance`) orders this correctly inside a single `tofu apply`. Compare logging, where the
  edge is `client → local_file → central.ipv4` — same mechanism, reversed direction.

### Feature tiers & flags

Every exporter and optional integration carries an individual `enable_<x>` boolean (see
*Provisioning options*). The flag governs **both** the cloud-init install/compose block **and**
the matching `prometheus.yml` scrape job — both are rendered inside `%{ if enable_x ~}…%{ endif ~}`
conditionals, so a disabled feature is neither installed nor scraped. The Prometheus/Grafana/
Alertmanager spine is unflagged (always on). A `enabled_exporters` output lists the active set
so the live test suite asserts only what is on.

Defaults: **MVP + Reach ON, Nice-to-have OFF.**

**MVP** — the spine plus baseline host metrics (default **on**):

| feature | flag | host | port | role |
|---------|------|------|------|------|
| Prometheus | *(spine)* | server | `9090` | scrape + metrics TSDB |
| Alertmanager | *(spine)* | server | `9093` | alert routing |
| Grafana | *(spine)* | server | `3000` | dashboards |
| OTel Collector | `enable_otel` | server | `4317`/`4318`/`8888` | OTLP gateway → Prometheus + OpenObserve |
| OpenObserve | `enable_openobserve` | server | `5080` | OTLP traces/metrics/logs store; Grafana datasource |
| blackbox_exporter | `enable_blackbox` | server | `9115` | HTTP/TCP/ICMP probes |
| node_exporter (`--collector.systemd`) | `enable_node_exporter` | both | `9100` | OS host + systemd-unit metrics |
| cAdvisor | `enable_cadvisor` | both | `8080` | container metrics |
| process-exporter | `enable_process_exporter` | client | `9256` | per-process metrics |
| netdata | `enable_netdata` | client | `19999` | real-time agent (`/api/v1/allmetrics?format=prometheus`) |

**Reach** — high homelab value (default **on**):

| feature | flag | host | port | role |
|---------|------|------|------|------|
| kube-state-metrics | `enable_kube_state_metrics` | client | in-cluster | k8s object state |
| kubelet/cAdvisor scrape | `enable_kubelet_scrape` | client | via k0s | k8s node + pod metrics |
| Heimdall | `enable_heimdall` | server | `80`/`443` | homepage / link dashboard |
| Uptime Kuma | `enable_uptime_kuma` | server | `3001` | human status page + notifications |
| Traefik | `enable_traefik` | server | `80`/`443`/`8082` | ingress fronting the stack + its own `/metrics` |
| nut_exporter | `enable_nut_exporter` | client | `9199` | UPS / Network UPS Tools metrics |
| nftables_exporter | `enable_nftables_exporter` | client | `9630` | firewall rule counters by proto/table/chain |
| statsd_exporter | `enable_statsd_exporter` | server | `9102`/`8125` | StatsD → Prometheus bridge |
| ssh_exporter | `enable_ssh_exporter` | server | `9312` | SSH endpoint probes |
| filestat_exporter | `enable_filestat_exporter` | client | `9943` | file size / mtime / stat metrics |

**Nice-to-have** — niche or heavy (default **off**):

| feature | flag | host | port | role |
|---------|------|------|------|------|
| osquery_exporter | `enable_osquery_exporter` | client | `9450` | osquery query results → metrics |
| ebpf_exporter | `enable_ebpf_exporter` | client | `9435` | custom eBPF metrics — **needs `linux-headers`** |
| texporter | `enable_texporter` | client | `9101` | eBPF network-traffic metrics — **needs `linux-headers`** |
| ffmpeg_exporter | `enable_ffmpeg_exporter` | client | `9618` | FFmpeg job metrics — only with media workloads |
| script_exporter | `enable_script_exporter` | client | `9469` | arbitrary shell-script metrics |
| Vector | `enable_vector` | server | `8686` | optional pipeline (alt to OTel; future logging route) |

`fluentd_exporter` is **N/A** for this lab — it shipped syslog-ng, not fluentd. Ports are
conventional defaults the implementer confirms per project.

### The server stack (`cloud-init/docker/compose.yaml.tftpl`)

One Docker Compose stack (mirrors the logging cluster's docker-client). The spine
(Prometheus/Alertmanager/Grafana) plus every MVP/Reach server service whose `enable_*` flag is
true is rendered into the compose file; with defaults that is Prometheus, Alertmanager, Grafana,
OpenObserve, OTel Collector, blackbox_exporter, Heimdall, Uptime Kuma, Traefik, statsd/ssh
exporters, and the server's self node_exporter/cAdvisor. When `enable_traefik` is on, Traefik
fronts Grafana/OpenObserve/Kuma/Heimdall on hostnames and is itself scraped; Vector is added
only when `enable_vector` is set. Prometheus loads the rendered `prometheus.yml` + `alert.rules.yml`.

### The monitored host (`cloud-init/k0s-client.yaml.tftpl`)

Single-node k0s plus the enabled exporter bundle — "anything that can be monitored should be."
Because the VM is an Ubuntu host running k0s, enabled exporters cover **both** layers: the OS
(node_exporter incl. systemd, process-exporter, netdata, and the Reach/Nice host exporters) and
the k8s node (kube-state-metrics + kubelet/cAdvisor). Each exporter's install block is gated on
its `enable_*` flag, so the client's footprint scales with what is turned on.

### Scrape jobs (rendered `prometheus.yml`)

Jobs are emitted **only for enabled features** (each wrapped in `%{ if enable_x ~}`). With
default flags the rendered jobs are:

| job | gated by | target(s) |
|-----|----------|-----------|
| `prometheus` | *(spine)* | server self `:9090` |
| `node` | `enable_node_exporter` | server `:9100` + k0s-client `<k0s_ip>:9100` |
| `cadvisor` | `enable_cadvisor` | server `:8080` + k0s-client `<k0s_ip>:8080` |
| `process` | `enable_process_exporter` | k0s-client `<k0s_ip>:9256` |
| `netdata` | `enable_netdata` | k0s-client `<k0s_ip>:19999` |
| `kube-state-metrics` | `enable_kube_state_metrics` | k0s-client in-cluster endpoint |
| `kubelet` | `enable_kubelet_scrape` | k0s-client kubelet/cAdvisor |
| `nut` | `enable_nut_exporter` | k0s-client `<k0s_ip>:9199` |
| `nftables` | `enable_nftables_exporter` | k0s-client `<k0s_ip>:9630` |
| `filestat` | `enable_filestat_exporter` | k0s-client `<k0s_ip>:9943` |
| `statsd` | `enable_statsd_exporter` | server `:9102` |
| `ssh` | `enable_ssh_exporter` | server `:9312` (probes targets) |
| `traefik` | `enable_traefik` | server `:8082` |
| `blackbox` | `enable_blackbox` | blackbox_exporter `:9115` probing Grafana/OpenObserve/k0s endpoints |
| `selfmetrics` | per-flag | alertmanager `:9093`, grafana `:3000`, openobserve `:5080`, otel `:8888` |

Disabled (default-off) Nice jobs — `osquery`, `ebpf`, `texporter`, `ffmpeg`, `script` — are not
rendered until their flag is set. The `<k0s_ip>` entries are the injected client IP — the single
value that forces the client-before-server ordering.

### Probing & alerting

- **blackbox_exporter** does Prometheus-driven probes (HTTP 200 / TLS / latency). Prometheus's
  `blackbox` job hits it with target URLs; `alert.rules.yml` fires on `probe_success == 0` or
  `up == 0`, routed through **Alertmanager**. Alertmanager defaults to a null/inhibit receiver
  in the lab (real notifiers are Future work).
- **Uptime Kuma** is the separate, human-facing status page — its own checks and notifications,
  independent of the Prometheus path. The two overlap deliberately: Kuma for the dashboard,
  blackbox for alertable time-series.

### OpenTelemetry & OpenObserve

- The **OTel Collector** runs on the server as a gateway: OTLP receivers on `4317` (gRPC) /
  `4318` (HTTP) → exports metrics to Prometheus (scraped via the collector's `:8888`) and
  traces/logs to **OpenObserve**.
- **OpenObserve** is the unified OTLP store and a **Grafana datasource** alongside Prometheus.
- The **k0s-client does not push OTLP** in this MVP: client-side OTLP would make the client
  depend on the server IP while the server already depends on the client IP — a Terraform
  dependency cycle. Server-side OTLP intake is built; client push is Future work.

### Grafana provisioning

Grafana datasources (Prometheus + OpenObserve) and a couple of starter dashboards
(node-exporter, cAdvisor/k8s) are provisioned from files dropped via cloud-init under
`grafana/provisioning/{datasources,dashboards}/` — no click-ops on first boot.

## Layout

```
multipass-lab/
├── Justfile                                   # root orchestrator (cluster arg)
├── specs/centralized_monitoring.md            # this document
└── clusters/centralized_monitoring/
    ├── versions.tf  providers.tf  variables.tf  terraform.tfvars
    ├── main.tf      outputs.tf     README.md   USAGE.md
    ├── cloud-init/
    │   ├── server.yaml.tftpl  k0s-client.yaml.tftpl
    │   ├── prometheus/{prometheus.yml.tftpl, alert.rules.yml, blackbox.yml}
    │   ├── alertmanager/alertmanager.yml
    │   ├── otel/collector-config.yaml
    │   ├── grafana/provisioning/{datasources,dashboards}/...
    │   └── docker/compose.yaml.tftpl
    ├── tests/tofu/sizing_and_render.tftest.hcl     # Layer 0/1 hermetic (mock_provider)
    └── tests/testinfra/                            # Layer 2 live verify (pytest+testinfra/SSH)
        ├── pyproject.toml  conftest.py
        └── test_server.py  test_k0s_client.py  test_e2e_scrape.py
```

## Provisioning options (variables)

Mirrors the logging cluster's variable style (per-role `object({cpus,memory,disk})` sizing,
hyphenated `name_prefix`, dual SSH-key inputs):

| variable | default | purpose |
|----------|---------|---------|
| `name_prefix` | `centralized-monitoring` | Multipass instance name prefix (hyphens only) |
| `image` | `24.04` | Ubuntu image alias |
| `ssh_pubkey_path` | `~/.ssh/id_ed25519.pub` | key injected into the `ubuntu` user (testinfra verify) |
| `ssh_pubkey` | `""` | inline key; overrides the path when non-empty (hermetic tests) |
| `server` | `{4, "8G", "40G"}` | server VM sizing |
| `k0s_client` | `{2, "4G", "30G"}` | monitored host sizing |
| `prometheus_scrape_interval` | `15s` | global scrape interval rendered into `prometheus.yml` |
| `grafana_admin_password` | `admin` (sensitive) | Grafana admin password |

Every exporter/integration is an individual `enable_*` bool (modelled like the logging cluster's
validated vars). Defaults encode the tier posture — **MVP + Reach `true`, Nice-to-have `false`**:

| flag | tier | default | governs |
|------|------|---------|---------|
| `enable_otel` | MVP | `true` | OTel Collector service + OTLP wiring |
| `enable_openobserve` | MVP | `true` | OpenObserve service + Grafana datasource |
| `enable_blackbox` | MVP | `true` | blackbox_exporter service + `blackbox` job |
| `enable_node_exporter` | MVP | `true` | node_exporter (both VMs) + `node` job |
| `enable_cadvisor` | MVP | `true` | cAdvisor (both VMs) + `cadvisor` job |
| `enable_process_exporter` | MVP | `true` | process-exporter + `process` job |
| `enable_netdata` | MVP | `true` | netdata + `netdata` job |
| `enable_kube_state_metrics` | Reach | `true` | kube-state-metrics + `kube-state-metrics` job |
| `enable_kubelet_scrape` | Reach | `true` | `kubelet`/cAdvisor k8s scrape job |
| `enable_heimdall` | Reach | `true` | Heimdall homepage service |
| `enable_uptime_kuma` | Reach | `true` | Uptime Kuma service |
| `enable_traefik` | Reach | `true` | Traefik ingress + `traefik` job |
| `enable_nut_exporter` | Reach | `true` | nut_exporter + `nut` job |
| `enable_nftables_exporter` | Reach | `true` | nftables_exporter + `nftables` job |
| `enable_statsd_exporter` | Reach | `true` | statsd_exporter + `statsd` job |
| `enable_ssh_exporter` | Reach | `true` | ssh_exporter + `ssh` job |
| `enable_filestat_exporter` | Reach | `true` | filestat_exporter + `filestat` job |
| `enable_osquery_exporter` | Nice | `false` | osquery_exporter + `osquery` job |
| `enable_ebpf_exporter` | Nice | `false` | ebpf_exporter + `ebpf` job (needs `linux-headers`) |
| `enable_texporter` | Nice | `false` | texporter + `texporter` job (needs `linux-headers`) |
| `enable_ffmpeg_exporter` | Nice | `false` | ffmpeg_exporter + `ffmpeg` job |
| `enable_script_exporter` | Nice | `false` | script_exporter + `script` job |
| `enable_vector` | Nice | `false` | Vector pipeline service |

The `enabled_exporters` output (a sorted list of the active flags) is consumed by
`tests/testinfra/conftest.py` so the live suite asserts only the exporters that are on.

## Testing — layered feedback loop

Mirrors the `boss-skills/specs` philosophy and the logging cluster: a hermetic inner loop,
then a live "real machine" rung verified with **pytest + testinfra**.

- **Layer 0/1 — hermetic (`just check`, no VMs)**: `tofu fmt -check`, `tofu validate`, and
  `tofu test -test-directory=tests/tofu` using `mock_provider "multipass"` (plan-only). Asserts:
  - sizing/image/names from tfvars (server `4/8G/40G`, k0s-client `2/4G/30G`,
    names `centralized-monitoring-{server,k0s}`).
  - the rendered `prometheus.yml` contains the **k0s client IP** as a scrape target and every
    expected job name (`node`, `cadvisor`, `process`, `netdata`, `kube-state-metrics`,
    `kubelet`, `blackbox`, `selfmetrics`).
  - the rendered compose stack contains the default-on server services (prometheus, alertmanager,
    grafana, openobserve, otel-collector, blackbox_exporter, heimdall, uptime-kuma, traefik,
    statsd/ssh exporters).
  - the k0s-client cloud-init installs the default-on exporter bundle + the injected SSH key.
  - a second `run` overriding `prometheus_scrape_interval` asserts the value renders.
  - **flag toggles**: a `run` with `enable_ebpf_exporter = true` asserts the eBPF install block
    **and** its `ebpf` scrape job now render; a `run` with `enable_nut_exporter = false` asserts
    the nut install block and `nut` job are **absent**; default-vars assert the Nice jobs
    (`osquery`/`ebpf`/`texporter`/`ffmpeg`/`script`) are **not** present.
- **Layer 2 — live verify (`just verify`, after `just up`)**: `uv run pytest` in
  `tests/testinfra`. `conftest.py` reads `tofu output -json` (`hosts` + `enabled_exporters`) and
  builds `ssh://ubuntu@<ip>` testinfra hosts (key injected via cloud-init). Checks are
  **parametrized over the enabled set** — a disabled exporter is skipped, not failed. Per role:
  - **server**: docker active; every enabled compose service running; its port listening
    (spine `9090/9093/3000`; enabled extras `5080/4317/9115/3001/8082/9102/9312…`).
  - **E2E (headline)**: query `http://localhost:9090/api/v1/targets` and assert **every**
    scrape target's health == `up` — proves the server is really pulling the client. Then query
    `up{instance=~"<k0s_ip>.*"} == 1` and a real metric (`node_load1`) returns data for the
    client instance. Because jobs are flag-gated, the target set equals `enabled_exporters`.
  - **blackbox**: when `enable_blackbox`, a probe of Grafana/OpenObserve returns `probe_success 1`.
  - **k0s-client**: each enabled exporter's port listening (node/cadvisor/process/netdata + any
    enabled Reach/Nice exporter); `k0s status` healthy; kube-state-metrics reachable when on.
  - **grafana**: datasources (Prometheus + OpenObserve) provisioned, verified via the Grafana API.

## Quickstart

```sh
just check centralized_monitoring    # hermetic
just up centralized_monitoring       # one apply -> 2 VMs (client first, server scrapes it)
multipass list                       # 2 Running with IPs
just verify centralized_monitoring   # services up / all Prometheus targets up / blackbox / grafana
just ssh centralized_monitoring server   # shell onto the server VM
just down centralized_monitoring     # destroy
```

Requires OpenTofu ≥ 1.7, `multipass`, `uv`, `just`, and an SSH keypair at
`~/.ssh/id_ed25519[.pub]`. The root `Justfile`'s generic recipes (`check / up / verify / down /
status / ssh / init / plan`) are cluster-name-parameterized and already work for
`centralized_monitoring` unchanged; a monitoring-specific `just targets`/`just urls`
convenience recipe is Future work.

## Applying cloud-init / config changes

The `larstobi/multipass` provider keys `multipass_instance` on the `cloudinit_file` **path**,
not its content — so editing a cloud-init template (e.g. changing `prometheus_scrape_interval`)
updates the rendered `.rendered/*.yaml` but does **not** recreate the VM on `tofu apply`.
Recreating the k0s-client alone also changes its DHCP IP, invalidating the scrape target the
server baked into `prometheus.yml`. To apply config changes, recreate the whole cluster:
`just down centralized_monitoring && just up centralized_monitoring`.

## Future work (kept in mind, not built here)

- **Converge with logging**: ship `centralized_logging`'s syslog-ng RFC5424 stream into
  **OpenObserve** so logs, metrics, and traces share one backend and one Grafana — the
  motivating reason OpenObserve is the sink here.
- **Client-side OTLP push**: have the k0s-client's OTel agent push traces/metrics to the server
  gateway. Needs the server→client dependency cycle broken — e.g. Prometheus `file_sd_configs`
  written post-apply, a two-pass apply, or `lifecycle { replace_triggered_by }`.
- **Vector pipeline** (`enable_vector`, default off): stand Vector up as an alternative/complement
  to the OTel Collector — a natural carrier for the future `centralized_logging → OpenObserve`
  route. `fluentd_exporter` is intentionally **not** included (this lab ships syslog-ng).
- **Nice-to-have exporters are one flag away**: `osquery`, `ebpf`/`texporter` (need
  `linux-headers`), `ffmpeg`, and `script` exporters ship off; flip their `enable_*` to evaluate.
- **InfluxDB + Telegraf** as an optional dedicated TSDB if a push-based long-retention store is
  wanted alongside Prometheus/OpenObserve.
- **Auto-recreate on cloud-init change**: `lifecycle { replace_triggered_by = [
  local_file.*.content_sha256 ] }` so `just up` rebuilds VMs when their cloud-init changes
  (server must re-render against the client's new IP) — removes the manual `down`/`up` step.
- **Real Alertmanager notifiers** (ntfy / email / Slack) in place of the lab's null receiver.
- **Promote to Proxmox** via Ansible roles — the same Prometheus/exporter configs apply, and the
  testinfra suite carries over to the Ansible/Proxmox rung unchanged (cloud-init key + SSH).
