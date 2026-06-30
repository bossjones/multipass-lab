# Endpoints & Ports

Every network endpoint in the cluster, grouped by VM. Ports are the endpoint's **listen** port
(what you reach at `<vm-ip>:<port>`). Each exporter is gated by an `enable_*` flag — see
[feature-flags.md](feature-flags.md). "✅ default" = on out of the box; "⬜ opt-in/off" = off by
default.

- [The log-shipping endpoint](#the-log-shipping-endpoint)
- [Human-facing web UIs (docker VM)](#human-facing-web-uis-docker-vm)
- [Docker Compose services](#docker-compose-services)
- [Exporters (all VMs)](#exporters-all-vms)
- [Useful HTTP endpoints](#useful-http-endpoints)

## The log-shipping endpoint

| Endpoint | Port | Proto | Purpose |
|----------|------|-------|---------|
| syslog-ng server (`central`) | `514` (`var.syslog_port`) | TCP, RFC 5424 | Both clients ship every journald log here; reliable disk-buffered, `flow-control` backpressure |

## Human-facing web UIs (docker VM)

Open these in a browser at the **docker** VM's IP (`just ssh centralized_logging docker` for a
shell, or read `tofu output hosts`):

| Service | URL | Default creds | Purpose |
|---------|-----|---------------|---------|
| Traefik dashboard | `http://<docker>:8080` | — | reverse proxy + ingress routing; auto-discovers labelled containers |
| Heimdall | `http://<docker>` (`:80`, via Traefik) | — | service portal / link homepage |
| Grafana | `http://<docker>:3000` | `admin` / `admin` | dashboards |
| Prometheus | `http://<docker>:9090` | — | scrapes itself + `traefik:8080` only (on-box stack, unrelated to the metrics layer below) |
| Alertmanager | `http://<docker>:9093` | — | `devnull` receiver (demo — drops everything) |

## Docker Compose services

Rendered from [`cloud-init/docker/compose.yaml.tftpl`](../cloud-init/docker/compose.yaml.tftpl).

| Service | Port(s) | Image | Notes |
|---------|---------|-------|-------|
| Traefik | `80`, `8080` | `traefik:v3.1` | web entrypoint `:80`; dashboard `:8080`; Docker provider auto-discovery |
| Heimdall | `80` (via Traefik) | `lscr.io/linuxserver/heimdall` | routed at `PathPrefix(/)` |
| Grafana | `3000` | `grafana/grafana` | `GF_SECURITY_ADMIN_PASSWORD=admin` |
| Prometheus | `9090` | `prom/prometheus` | on-box scrape config, **not** the metrics-layer exporters below |
| Alertmanager | `9093` | `prom/alertmanager` | demo `devnull` receiver |

## Exporters (all VMs)

Installed flag-gated via a copied `install-exporter.sh` helper (downloads a GitHub release, drops
a systemd unit; `{ARCH}` substituted with `arm64`/`amd64`). All listeners bind `0.0.0.0` — the
precondition for a future cross-VM scrape, but **nothing scrapes them locally today**.

| Exporter / endpoint | central | docker | k0s | Port | Metrics path | Flag | Default |
|---|:--:|:--:|:--:|---|---|---|:--:|
| node_exporter | ✅ | ✅ | ✅ | `9100` | `/metrics` | `enable_node_exporter` | ✅ |
| syslog-ng metrics (textfile) | ✅ | ✅ | ✅ | via `9100` | `/metrics` | `enable_syslogng_metrics` | ✅ |
| systemd_exporter | ✅ | ✅ | ✅ | `9558` | `/metrics` | `enable_systemd_exporter` | ✅ |
| journald-exporter | ✅ | ✅ | ✅ | `12345` | `/metrics` | `enable_journald_exporter` | ⬜ (x86-64-only binary) |
| process-exporter | ✅ | ✅ | ✅ | `9256` | `/metrics` | `enable_process_exporter` | ✅ |
| filestat_exporter | ✅ | — | — | `9943` | `/metrics` | `enable_filestat_exporter` | ✅ (central only) |
| cAdvisor | — | ✅ | ✅ | `8089` | `/metrics` | `enable_cadvisor` | ✅ |
| Traefik metrics | — | ✅ | — | `8082` | `/metrics` | `enable_traefik_metrics` | ✅ |
| kube-proxy | — | — | ✅ | `10249` | `/metrics` | `enable_kube_metrics` | ✅ |
| kubelet (read-only) | — | — | ✅ | `10255` | `/metrics/cadvisor` | `enable_kube_metrics` | ✅ |
| kube-state-metrics | — | — | ✅ | `8081` | `/metrics` | `enable_kube_state_metrics` | ✅ (hostNetwork Deployment) |

> ‡ cAdvisor uses **`:8089`** on docker and k0s because `:8080` is taken by Traefik / kube-router
> respectively — same convention as `centralized_monitoring`.

## Useful HTTP endpoints

Verifying an exporter directly (run from inside a VM via `just ssh`):

```sh
just ssh centralized_logging central
# host + syslog-ng textfile metrics
curl -fsS http://localhost:9100/metrics | grep syslogng_ | head
# systemd_exporter sees the syslog-ng unit
curl -fsS http://localhost:9558/metrics | grep 'syslog-ng.service'
# the textfile the timer maintains
cat /var/lib/node_exporter/textfile_collector/syslogng.prom | head
```

Cross-VM reachability proves the `0.0.0.0` bind (the precondition for a future scrape):

```sh
tofu -chdir=clusters/centralized_logging output -json metrics_targets
just ssh centralized_logging k0s
curl -fsS http://<central_ip>:9100/metrics | head
```

| Endpoint | Returns |
|----------|---------|
| `http://<vm-ip>:9100/metrics` | node_exporter output, including the `syslogng_*` textfile series |
| `http://<vm-ip>:9558/metrics` | systemd_exporter per-unit health |
| `http://<docker>:8080/api/http/routers` | Traefik's discovered routers (API, unauthenticated) |
| `http://admin:admin@<docker>:3000/api/datasources` | JSON of the on-box Grafana datasource (Prometheus only) |

See [feature-flags.md](feature-flags.md) for how each flag gates the install above, and
[dependencies.md](dependencies.md) for the exporter binary versions and upstream sources.
