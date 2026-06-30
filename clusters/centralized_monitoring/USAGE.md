# centralized_monitoring — USAGE

A deep-dive companion to [`README.md`](README.md) and the design spec
[`specs/centralized_monitoring.md`](../../specs/centralized_monitoring.md). This cluster stands up
a pull-based observability stack: a Prometheus/Grafana/OpenObserve **server** that scrapes a
fully-instrumented single-node **k0s** host.

> 📚 For the full reference — Mermaid diagrams, the complete endpoint/port catalog, the open-source
> dependency tables, and the feature-flag matrix — see [`docs/`](docs/):
> [architecture](docs/architecture.md) · [endpoints](docs/endpoints.md) ·
> [feature flags](docs/feature-flags.md) · [dependencies](docs/dependencies.md) ·
> [operations](docs/operations.md).

## 1. Architecture & the inverted IP edge

```
        ┌──────────────────────────────┐  node_exporter :9100  ─┐
        │ centralized-monitoring-k0s   │  cadvisor      :8080   │
        │  k0s --single                │  process-exp   :9256   │  Prometheus
        │  + full exporter bundle      │  netdata       :19999  │  scrape (PULL)
        └──────────────────────────────┘  kube-state-metrics    │  HTTP /metrics
                                           kubelet/cAdvisor     ◀┘
                                                        ▲
        ┌──────────────────────────────────────────────┴───────────────┐
        │ centralized-monitoring-server                                 │
        │  docker compose: prometheus :9090 · alertmanager :9093        │
        │  grafana :3000 · openobserve :5080 · otel :4317/18            │
        │  uptime-kuma :3001 · heimdall :80 · blackbox :9115            │
        └───────────────────────────────────────────────────────────────┘
```

Because Prometheus **pulls**, the scrape target must exist before the server is rendered. So
unlike the logging cluster (central first, clients reference central IP), here the **k0s-client is
created first** and the server's `prometheus.yml` is rendered from the client's runtime `ipv4`.
The edge that forces it lives in [`main.tf`](main.tf): `prometheus_yml` references
`multipass_instance.k0s.ipv4`, giving the chain `server → local_file.server_ci → prometheus_yml
→ k0s.ipv4 → k0s instance`.

## 2. Lifecycle

| step | command | what happens |
|------|---------|--------------|
| hermetic check | `just check centralized_monitoring` | `tofu fmt -check` + `validate` + `tofu test` (mock provider, no VMs) |
| up | `just up centralized_monitoring` | one `tofu apply`: renders k0s cloud-init → launches k0s → reads its IP → renders `prometheus.yml` + server cloud-init → launches server; then blocks on `cloud-init status --wait` over SSH |
| verify | `just verify centralized_monitoring` | `uv run pytest` in `tests/testinfra` over SSH |
| shell | `just ssh centralized_monitoring server` | SSH onto a VM by role |
| down | `just down centralized_monitoring` | `tofu destroy` |

## 3. Cloud-init breakdown

- **`cloud-init/k0s-client.yaml.tftpl`** — installs single-node k0s, then a flag-gated install
  block per exporter (a shared `/usr/local/sbin/install-exporter.sh` helper downloads each release
  and registers a systemd unit). kube-state-metrics is applied into the cluster with `k0s kubectl`.
- **`cloud-init/server.yaml.tftpl`** — drops the rendered `prometheus.yml`, `alert.rules.yml`,
  `alertmanager.yml`, blackbox/otel configs, and Grafana provisioning, then installs Docker and
  runs `docker compose up -d`.
- **`cloud-init/docker/compose.yaml.tftpl`** — the spine (Prometheus/Alertmanager/Grafana) plus
  every enabled server service. When `enable_traefik` is on it fronts Heimdall on a hostname;
  otherwise services publish ports directly.
- **`cloud-init/prometheus/prometheus.yml.tftpl`** — one `%{ if enable_x ~}` scrape job per
  feature; client jobs target `${k0s_ip}:<port>`.
- **`cloud-init/grafana/provisioning/…`** — Prometheus (always) + OpenObserve (when enabled)
  datasources and two starter dashboards, so there is no click-ops on first boot.

> Generated `.rendered/*.yaml` is gitignored and re-rendered every apply — don't hand-edit it.

## 4. Configuration reference

Core variables (see [`variables.tf`](variables.tf)):

| variable | default | purpose |
|----------|---------|---------|
| `name_prefix` | `centralized-monitoring` | Multipass instance name prefix (hyphens) |
| `image` | `24.04` | Ubuntu image alias |
| `ssh_pubkey_path` / `ssh_pubkey` | `~/.ssh/id_ed25519.pub` / `""` | key injected into the `ubuntu` user (inline overrides path) |
| `server` | `{4,"8G","40G"}` | server VM sizing |
| `k0s_client` | `{2,"4G","30G"}` | monitored host sizing |
| `prometheus_scrape_interval` | `15s` | global scrape interval |
| `grafana_admin_password` | `admin` (sensitive) | Grafana admin password |

Feature flags — **MVP + Reach default `true`, Nice-to-have default `false`**. Each gates both the
install/compose block and the scrape job:

| tier | flags |
|------|-------|
| MVP (on) | `enable_otel` `enable_openobserve` `enable_blackbox` `enable_node_exporter` `enable_cadvisor` `enable_process_exporter` `enable_netdata` |
| Reach (on) | `enable_kube_state_metrics` `enable_kubelet_scrape` `enable_heimdall` `enable_uptime_kuma` `enable_traefik` `enable_statsd_exporter` `enable_ssh_exporter` `enable_filestat_exporter` |
| Reach but **off** (lab-hostile) | `enable_nut_exporter`† `enable_nftables_exporter`‡ |
| Nice (off) | `enable_osquery_exporter` `enable_ebpf_exporter`* `enable_texporter`* `enable_ffmpeg_exporter` `enable_script_exporter` `enable_vector` |

`*` need kernel `linux-headers` (the install block pulls them). `†` `nut_exporter` needs a running
`upsd`/UPS — absent in a lab VM. `‡` `nftables_exporter` ships only as a Python tool (no portable
binary release). Both stay flag-available; flip them on for a host that supports them. The
`enabled_exporters` output is a sorted list of the active flags, consumed by
`tests/testinfra/conftest.py`.

> **Arch note:** exporter binaries are installed via `install-exporter.sh`, which substitutes
> `{ARCH}` (arm64/amd64 from `dpkg`) into each release URL — so the bundle works on Apple-Silicon
> Multipass (arm64) and amd64 Proxmox alike. kube-state-metrics runs as a **host binary** against
> the k0s admin kubeconfig (a ClusterIP Service is unreachable from the server), and the kubelet
> job uses the **read-only port 10255** (http, no token), enabled via k0s `--kubelet-extra-args`.

### Scrape jobs (rendered with default flags)

`prometheus` (spine) · `node` · `cadvisor` · `process` · `netdata` · `kube-state-metrics` ·
`kubelet` · `filestat` · `statsd` · `ssh` · `traefik` · `blackbox` · `selfmetrics`. The
lab-hostile `nut`/`nftables` jobs and the Nice jobs (`osquery`/`ebpf`/`texporter`/`ffmpeg`/`script`)
render only when their flag is set.

## 5. Testing — layered

- **Layer 0/1 hermetic** (`tests/tofu/sizing_and_render.tftest.hcl`, `mock_provider`, plan-only):
  sizing/image/names; the injected k0s IP is a scrape target; default job names + compose services
  render; the k0s exporter bundle + SSH key render; a scrape-interval override renders; an eBPF
  toggle-on renders its install block (+`linux-headers`) and `ebpf` job; a nut toggle-off drops
  both; Nice jobs are absent by default.
- **Layer 2 live** (`tests/testinfra/`, pytest + testinfra over SSH, parametrized over
  `enabled_exporters`): `test_server.py` (docker + enabled service ports), `test_k0s_client.py`
  (k0s healthy + enabled exporter ports + kube-state-metrics), `test_e2e_scrape.py` (headline —
  **all Prometheus targets `up`**, client `up==1` + `node_load1`, blackbox `probe_success 1`,
  Grafana datasources provisioned).

## 6. Troubleshooting

| symptom | cause / fix |
|---------|-------------|
| a Prometheus target is `down` | the exporter is still installing; re-check after cloud-init settles. Some Nice/Reach exporter release URLs may need version bumps — see `cloud-init/k0s-client.yaml.tftpl` |
| config edit didn't take | the provider keys on the cloud-init **path**, not content — recreate the cluster (`just down && just up`) |
| `just verify` can't reach a VM | confirm `~/.ssh/id_ed25519` matches the injected pubkey; host keys reset every `up` (testinfra disables host-key checking) |
| OpenObserve datasource missing in Grafana | the `zinclabs-openobserve-datasource` plugin install needs network on first boot; check the grafana container logs |

## 7. Future work

Converge logging into OpenObserve; client-side OTLP push (needs the server→client cycle broken);
real Alertmanager notifiers; promote to Proxmox via Ansible (the testinfra suite carries over).
See the spec's *Future work* section.
