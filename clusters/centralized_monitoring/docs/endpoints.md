# Endpoints & Ports

Every network endpoint in the cluster, grouped by VM. Ports are the **host-published** ports (what
you reach at `<vm-ip>:<port>`). Each service/exporter is gated by an `enable_*` flag — see
[feature-flags.md](feature-flags.md). "✅ default" = on out of the box; "⬜ opt-in" = off by default.

- [Human-facing web UIs](#human-facing-web-uis)
- [Server services (Docker Compose)](#server-services-docker-compose)
- [k0s exporters (host binaries + k8s)](#k0s-exporters-host-binaries--k8s)
- [Prometheus scrape jobs](#prometheus-scrape-jobs)
- [Useful HTTP API endpoints](#useful-http-api-endpoints)
- [OpenTelemetry Collector endpoints](#opentelemetry-collector-endpoints)

## Human-facing web UIs

Open these in a browser at the **server** IP (`just ssh centralized_monitoring server` to get a shell,
or read `tofu output hosts`):

| Service | URL | Default creds | Purpose | Flag |
|---------|-----|---------------|---------|------|
| Grafana | `http://<server>:3000` | `admin` / `admin` | Dashboards + datasources | spine (always) |
| Prometheus | `http://<server>:9090` | — | PromQL UI + target health | spine (always) |
| Alertmanager | `http://<server>:9093` | — | Alert routing UI | spine (always) |
| OpenObserve | `http://<server>:5080` | `admin@example.com` / `Complexpass#123` | OTLP traces/metrics/logs explorer | `enable_openobserve` ✅ |
| Uptime Kuma | `http://<server>:3001` | set on first visit | Human status page | `enable_uptime_kuma` ✅ |
| Heimdall | `http://<server>:80` | — | Homepage / link dashboard | `enable_heimdall` ✅ † |
| Traefik dashboard | `http://<server>:8082` | — | Ingress routing + `/metrics` | `enable_traefik` ✅ |

> † When `enable_traefik` is on, Heimdall is **not** published on `:80` directly — Traefik fronts it
> at the host rule `heimdall.localhost`. With Traefik off, Heimdall publishes `:80` itself.

## Server services (Docker Compose)

Rendered from [`cloud-init/docker/compose.yaml.tftpl`](../cloud-init/docker/compose.yaml.tftpl).

| Service | Port(s) | Proto | Image | Metrics path | Flag |
|---------|---------|-------|-------|--------------|------|
| Prometheus | `9090` | HTTP | `prom/prometheus:latest` | `/metrics` | spine (always) |
| Alertmanager | `9093` | HTTP | `prom/alertmanager:latest` | `/metrics` | spine (always) |
| Grafana | `3000` | HTTP | `grafana/grafana:latest` | `/metrics` | spine (always) |
| node_exporter | `9100` | HTTP | `prom/node-exporter:latest` | `/metrics` | `enable_node_exporter` ✅ |
| cAdvisor | `8080` | HTTP | `gcr.io/cadvisor/cadvisor:latest` | `/metrics` | `enable_cadvisor` ✅ |
| OpenObserve | `5080` | HTTP | `public.ecr.aws/zinclabs/openobserve:latest` | `/api/default/prometheus`, `/healthz` | `enable_openobserve` ✅ |
| OTel Collector | `4317`, `4318`, `8888` | gRPC / HTTP / HTTP | `otel/opentelemetry-collector-contrib:latest` | `:8888` | `enable_otel` ✅ |
| blackbox_exporter | `9115` | HTTP | `prom/blackbox-exporter:latest` | `/probe`, `/metrics` | `enable_blackbox` ✅ |
| Heimdall | `80` † | HTTP | `lscr.io/linuxserver/heimdall:latest` | — | `enable_heimdall` ✅ |
| Uptime Kuma | `3001` | HTTP | `louislam/uptime-kuma:1` | — | `enable_uptime_kuma` ✅ |
| Traefik | `80`, `443`, `8082` | HTTP/HTTPS/HTTP | `traefik:v3.1` | `:8082/metrics` | `enable_traefik` ✅ |
| statsd_exporter | `9102` (TCP), `8125` (UDP) | TCP / UDP | `prom/statsd-exporter:latest` | `:9102/metrics` | `enable_statsd_exporter` ✅ |
| ssh_exporter | `9312` | HTTP | `treydock/ssh_exporter:latest` | `/metrics`, `/ssh` | `enable_ssh_exporter` ✅ |
| Vector | `8686` | HTTP | `timberio/vector:latest-debian` | — | `enable_vector` ⬜ |

Persistent Docker volumes: `prometheus_data`, `grafana_data` (always); `openobserve_data`,
`heimdall_config`, `uptime_kuma_data` (when their service is enabled).

## k0s exporters (host binaries + k8s)

Installed by [`cloud-init/k0s-client.yaml.tftpl`](../cloud-init/k0s-client.yaml.tftpl) via the shared
`install-exporter.sh` helper (downloads a GitHub release, drops a systemd unit). Scraped by the
server at `${k0s_ip}:<port>`.

| Exporter / endpoint | Port | Metrics path | Source | Flag |
|---------------------|------|--------------|--------|------|
| k0s API server | `6443` | — | k0s | always (k0s) |
| kubelet (read-only) | `10255` | `/metrics/cadvisor` | k0s `--kubelet-extra-args` | `enable_kubelet_scrape` ✅ |
| node_exporter | `9100` | `/metrics` | binary `v1.8.2` | `enable_node_exporter` ✅ |
| cAdvisor | `8089` | `/metrics` | binary `v0.49.1` (‡) | `enable_cadvisor` ✅ |
| process-exporter | `9256` | `/metrics` | binary `v0.8.4` | `enable_process_exporter` ✅ |
| netdata | `19999` | `/api/v1/allmetrics?format=prometheus` | kickstart (latest) | `enable_netdata` ✅ |
| kube-state-metrics | `8081` | `/metrics` | `:v2.13.0` (hostNetwork Deployment) | `enable_kube_state_metrics` ✅ |
| filestat_exporter | `9943` | `/metrics` | binary `v0.4.5` | `enable_filestat_exporter` ✅ |
| nut_exporter | `9199` | `/metrics` | binary `v3.2.5` | `enable_nut_exporter` ⬜ (lab-hostile) |
| nftables_exporter | `9630` | `/metrics` | binary `2.1.0` | `enable_nftables_exporter` ⬜ (lab-hostile) |
| osquery_exporter | `9450` | `/metrics` | binary `v0.1.1` | `enable_osquery_exporter` ⬜ |
| ebpf_exporter | `9435` | `/metrics` | binary `v2.4.2` (needs linux-headers) | `enable_ebpf_exporter` ⬜ |
| texporter | `9101` | `/metrics` | binary `v0.1.0` (needs linux-headers) | `enable_texporter` ⬜ |
| ffmpeg_exporter | `9618` | `/metrics` | binary `v0.1.0` | `enable_ffmpeg_exporter` ⬜ |
| script_exporter | `9469` | `/probe` | binary `v2.18.0` | `enable_script_exporter` ⬜ |

> ‡ On the k0s host cAdvisor uses **`:8089`** because `:8080` is taken by the k0s kube-router. On the
> **server**, cAdvisor uses the standard `:8080`.

## Prometheus scrape jobs

Rendered from [`cloud-init/prometheus/prometheus.yml.tftpl`](../cloud-init/prometheus/prometheus.yml.tftpl).
Global `scrape_interval` defaults to `15s` (`prometheus_scrape_interval`). Service names like
`grafana`, `alertmanager` resolve on the Compose network; `${k0s_ip}` is the injected k0s IP.

| Job | Enabled by | Target(s) | `metrics_path` |
|-----|-----------|-----------|----------------|
| `prometheus` | spine (always) | `localhost:9090` | `/metrics` |
| `node` | `enable_node_exporter` ✅ | `node_exporter:9100`, `${k0s_ip}:9100` | `/metrics` |
| `cadvisor` | `enable_cadvisor` ✅ | `cadvisor:8080`, `${k0s_ip}:8089` | `/metrics` |
| `process` | `enable_process_exporter` ✅ | `${k0s_ip}:9256` | `/metrics` |
| `netdata` | `enable_netdata` ✅ | `${k0s_ip}:19999` | `/api/v1/allmetrics?format=prometheus` |
| `kube-state-metrics` | `enable_kube_state_metrics` ✅ | `${k0s_ip}:8081` | `/metrics` |
| `kubelet` | `enable_kubelet_scrape` ✅ | `${k0s_ip}:10255` | `/metrics/cadvisor` |
| `filestat` | `enable_filestat_exporter` ✅ | `${k0s_ip}:9943` | `/metrics` |
| `statsd` | `enable_statsd_exporter` ✅ | `statsd_exporter:9102` | `/metrics` |
| `ssh` | `enable_ssh_exporter` ✅ | `ssh_exporter:9312` | `/metrics` |
| `traefik` | `enable_traefik` ✅ | `traefik:8082` | `/metrics` |
| `blackbox` | `enable_blackbox` ✅ | probes (see below) via `blackbox_exporter:9115` | `/probe` |
| `selfmetrics` | spine (always) | `alertmanager:9093`, `grafana:3000`, `otel-collector:8888` (if `enable_otel`) | `/metrics` |
| `nut` | `enable_nut_exporter` ⬜ | `${k0s_ip}:9199` | `/metrics` |
| `nftables` | `enable_nftables_exporter` ⬜ | `${k0s_ip}:9630` | `/metrics` |
| `osquery` | `enable_osquery_exporter` ⬜ | `${k0s_ip}:9450` | `/metrics` |
| `ebpf` | `enable_ebpf_exporter` ⬜ | `${k0s_ip}:9435` | `/metrics` |
| `texporter` | `enable_texporter` ⬜ | `${k0s_ip}:9101` | `/metrics` |
| `ffmpeg` | `enable_ffmpeg_exporter` ⬜ | `${k0s_ip}:9618` | `/metrics` |
| `script` | `enable_script_exporter` ⬜ | `${k0s_ip}:9469` | `/probe` |

**Default scrape jobs (13):** `prometheus`, `node`, `cadvisor`, `process`, `netdata`,
`kube-state-metrics`, `kubelet`, `filestat`, `statsd`, `ssh`, `traefik`, `blackbox`, `selfmetrics`.

### Blackbox probe targets & modules

The `blackbox` job probes (module `http_2xx`):

- `http://grafana:3000/login`
- `http://openobserve:5080/healthz` (only when `enable_openobserve`)
- `http://${k0s_ip}:9100/metrics`

Modules defined in [`blackbox.yml`](../cloud-init/prometheus/blackbox.yml): `http_2xx` (HTTP, IPv4,
5s), `tcp_connect` (TCP, 5s), `icmp` (ICMP, IPv4, 5s).

### Alert rules

From [`alert.rules.yml`](../cloud-init/prometheus/alert.rules.yml) (routed via Alertmanager, which
uses a null `devnull` receiver in the lab):

| Alert | Expression | For | Severity |
|-------|-----------|-----|----------|
| `TargetDown` | `up == 0` | 1m | critical |
| `BlackboxProbeFailed` | `probe_success == 0` | 1m | warning |

## Useful HTTP API endpoints

| Endpoint | Returns |
|----------|---------|
| `http://<server>:9090/api/v1/targets` | JSON list of scrape targets + per-target `health` (used by the e2e test) |
| `http://<server>:9090/api/v1/query?query=up` | PromQL instant query |
| `http://<server>:9115/probe?module=http_2xx&target=<url>` | raw blackbox probe result (`probe_success 1`) |
| `http://admin:admin@<server>:3000/api/datasources` | JSON of provisioned Grafana datasources |
| `http://<server>:5080/healthz` | OpenObserve health check |
| `http://<server>:5080/api/default/prometheus` | OpenObserve PromQL-compatible API (the Grafana datasource URL) |

These endpoints are wrapped by the host-side **verification CLIs** — `just grafana-check`,
`just prometheus-check`, `just openobserve-check` (or `just verify-api` for all three), plus
introspection recipes (`just prometheus-targets`, `just grafana-datasources`,
`just openobserve-streams`, …). They resolve the server IP from `tofu output` and exit
nonzero on failure. See [`specs/cli-grafana.md`](../../../specs/cli-grafana.md),
[`specs/cli-prometheus.md`](../../../specs/cli-prometheus.md), and
[`specs/cli-openobserve.md`](../../../specs/cli-openobserve.md).

## OpenTelemetry Collector endpoints

From [`collector-config.yaml`](../cloud-init/otel/collector-config.yaml):

| Endpoint | Role |
|----------|------|
| `0.0.0.0:4317` (gRPC), `0.0.0.0:4318` (HTTP) | OTLP receivers (apps push traces/metrics/logs) |
| `:8888` | Collector self-telemetry, scraped by the `selfmetrics` job |
| `0.0.0.0:8889` | internal Prometheus exporter endpoint for the metrics pipeline |
| `http://openobserve:5080/api/default` (OTLP HTTP) | traces + logs export to OpenObserve |

Pipelines: **traces → OpenObserve**, **metrics → Prometheus**, **logs → OpenObserve**.
