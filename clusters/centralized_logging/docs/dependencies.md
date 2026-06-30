# Open-Source Dependencies

Every open-source project the `centralized_logging` cluster pulls in, with versions and upstream
links. Versions are pinned where the source pins them; exporter binary versions come from the
shared `install-exporter.sh` blocks in each `*.tftpl` cloud-init template.

- [OpenTofu providers](#opentofu-providers)
- [Log pipeline](#log-pipeline)
- [Client workloads](#client-workloads)
- [Exporters](#exporters)
- [Test toolchain](#test-toolchain)

## OpenTofu providers

Declared in [`versions.tf`](../versions.tf); `required_version >= 1.7`.

| Provider | Source | Constraint | Purpose | Registry |
|----------|--------|-----------|---------|----------|
| multipass | `larstobi/multipass` | `~> 1.4` | Provision Multipass VMs | [registry](https://registry.terraform.io/providers/larstobi/multipass/latest) · [repo](https://github.com/larstobi/terraform-provider-multipass) |
| local | `hashicorp/local` | `~> 2.4` | Render cloud-init to `.rendered/` | [registry](https://registry.terraform.io/providers/hashicorp/local/latest) · [repo](https://github.com/hashicorp/terraform-provider-local) |

Underlying tools: [OpenTofu](https://opentofu.org/), [Multipass](https://multipass.run/),
[just](https://github.com/casey/just), [uv](https://github.com/astral-sh/uv).

## Log pipeline

| Component | Home | Source / Docs |
|-----------|------|----------------|
| syslog-ng (Open Source Edition) | [syslog-ng.com](https://www.syslog-ng.com/technical-documents/list/syslog-ng-open-source-edition) | [GitHub](https://github.com/syslog-ng/syslog-ng) · [admin guide](https://syslog-ng.github.io/admin-guide/) |
| systemd-journald | [freedesktop.org](https://www.freedesktop.org/software/systemd/man/latest/systemd-journald.service.html) | [systemd](https://systemd.io/) |
| RFC 5424 (Syslog Protocol) | [IETF](https://datatracker.ietf.org/doc/html/rfc5424) | — |
| VictoriaLogs *(future sink)* | [docs](https://docs.victoriametrics.com/victorialogs/) | [GitHub](https://github.com/VictoriaMetrics/VictoriaMetrics) |
| OpenObserve *(future sink)* | [openobserve.ai](https://openobserve.ai/) | [GitHub](https://github.com/openobserve/openobserve) |

VMs run syslog-ng `4.3.1` (confirmed live); the server config carries commented stubs for
swapping the `file()` sink to VictoriaLogs or OpenObserve (both ingest RFC 5424) without
touching the clients.

## Client workloads

| Component | Home | Source / Docs |
|-----------|------|----------------|
| k0s (Kubernetes) | [k0sproject.io](https://k0sproject.io/) | [GitHub](https://github.com/k0sproject/k0s) · [docs](https://docs.k0sproject.io/) |
| Kubernetes | [kubernetes.io](https://kubernetes.io/) | — |
| containerd | [containerd.io](https://containerd.io/) | — |
| Docker | [docker.com](https://www.docker.com/) | [docs](https://docs.docker.com/) · [Compose](https://docs.docker.com/compose/) |
| Traefik | [traefik.io](https://traefik.io/) (`traefik:v3.1`) | [GitHub](https://github.com/traefik/traefik) · [docs](https://doc.traefik.io/traefik/) |
| Grafana | [grafana.com](https://grafana.com/) (`grafana/grafana`) | [GitHub](https://github.com/grafana/grafana) |
| Prometheus | [prometheus.io](https://prometheus.io/) (`prom/prometheus`) | [GitHub](https://github.com/prometheus/prometheus) |
| Alertmanager | [docs](https://prometheus.io/docs/alerting/latest/alertmanager/) (`prom/alertmanager`) | [GitHub](https://github.com/prometheus/alertmanager) |
| Heimdall | [heimdall.site](https://heimdall.site/) (`lscr.io/linuxserver/heimdall`) | [GitHub](https://github.com/linuxserver/Heimdall) |

The on-box Docker Compose stack (Traefik/Heimdall/Grafana/Prometheus/Alertmanager) predates the
metrics-exporter layer and is intentionally left as-is — its Prometheus still only scrapes
itself + `traefik:8080`. See [endpoints.md](endpoints.md#docker-compose-services).

## Exporters

Installed flag-gated via a copied `install-exporter.sh` helper (downloads a GitHub release,
drops a systemd unit; `{ARCH}` substituted with `arm64`/`amd64` from `dpkg`, reused verbatim
from `centralized_monitoring`).

| Exporter | Version | Port | Gated by | Release |
|----------|---------|------|----------|---------|
| node_exporter | `1.8.2` | `9100` | `enable_node_exporter` | [releases](https://github.com/prometheus/node_exporter/releases/tag/v1.8.2) |
| syslog-ng metrics (textfile) | native (`4.3.1`) | via `9100` | `enable_syslogng_metrics` | [`syslog-ng-ctl stats prometheus`](https://www.syslog-ng.com/community/b/blog/posts/syslog-ng-prometheus-exporter) |
| systemd_exporter | `0.7.0` | `9558` | `enable_systemd_exporter` | [releases](https://github.com/prometheus-community/systemd_exporter) |
| process-exporter | `0.8.4` | `9256` | `enable_process_exporter` | [releases](https://github.com/ncabatoff/process-exporter/releases/tag/v0.8.4) |
| filestat_exporter | `0.4.5` | `9943` | `enable_filestat_exporter` | [releases](https://github.com/michael-doubez/filestat_exporter/releases/tag/v0.4.5) |
| cAdvisor | `0.49.1` | `8089` | `enable_cadvisor` | [releases](https://github.com/google/cadvisor/releases/tag/v0.49.1) |
| kube-state-metrics | `registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.13.0` | `8081` | `enable_kube_state_metrics` | [GitHub](https://github.com/kubernetes/kube-state-metrics) |
| journald-exporter *(off — x86-64 only)* | `1.0.0` | `12345` | `enable_journald_exporter` | [dead-claudia/journald-exporter](https://github.com/dead-claudia/journald-exporter) |

> Some off-by-default or pinned-version release URLs may need version bumps over time (upstream
> tags move/disappear). If a target shows `down`, check the relevant `*.tftpl` template's install
> block.

## Test toolchain

Live tests under [`tests/testinfra/`](../tests/testinfra/) (managed by `uv`):

| Tool | Purpose | Upstream |
|------|---------|----------|
| pytest | test runner | https://github.com/pytest-dev/pytest |
| pytest-testinfra | assert over SSH against running VMs | https://github.com/pytest-dev/pytest-testinfra |
| pytest-xdist | parallel test execution | https://github.com/pytest-dev/pytest-xdist |

Hermetic tests use OpenTofu's native `tofu test` with `mock_provider "multipass" {}` — no extra
dependency. See [operations.md](operations.md#testing).
