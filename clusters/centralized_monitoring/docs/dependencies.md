# Open-Source Dependencies

Every open-source project the `centralized_monitoring` cluster pulls in, with versions and upstream
links. Versions are pinned where the source pins them; `latest` / `1` / `v3.1` are the literal tags
used in [`compose.yaml.tftpl`](../cloud-init/docker/compose.yaml.tftpl), and exporter binary versions
come from [`k0s-client.yaml.tftpl`](../cloud-init/k0s-client.yaml.tftpl).

- [OpenTofu providers](#opentofu-providers)
- [Server stack — Docker images](#server-stack--docker-images)
- [k0s host — exporter binaries](#k0s-host--exporter-binaries)
- [Kubernetes components](#kubernetes-components)
- [OS packages & install scripts](#os-packages--install-scripts)
- [Test toolchain](#test-toolchain)

## OpenTofu providers

Declared in [`versions.tf`](../versions.tf); `required_version >= 1.7`.

| Provider | Source | Constraint | Locked | Purpose | Registry |
|----------|--------|-----------|:------:|---------|----------|
| multipass | `larstobi/multipass` | `~> 1.4` | `1.4.3` | Provision Multipass VMs | [registry](https://registry.terraform.io/providers/larstobi/multipass/latest) · [repo](https://github.com/larstobi/terraform-provider-multipass) |
| local | `hashicorp/local` | `~> 2.4` | `2.9.0` | Render cloud-init to `.rendered/` | [registry](https://registry.terraform.io/providers/hashicorp/local/latest) · [repo](https://github.com/hashicorp/terraform-provider-local) |

Underlying tools: [OpenTofu](https://opentofu.org/), [Multipass](https://multipass.run/),
[just](https://github.com/casey/just), [uv](https://github.com/astral-sh/uv).

## Server stack — Docker images

Run via Docker Compose on the server VM (Docker installed from [get.docker.com](https://get.docker.com)).

| Project | Image (tag) | Gated by | Upstream |
|---------|-------------|----------|----------|
| Prometheus | `prom/prometheus:latest` | spine | https://github.com/prometheus/prometheus |
| Alertmanager | `prom/alertmanager:latest` | spine | https://github.com/prometheus/alertmanager |
| Grafana | `grafana/grafana:latest` | spine | https://github.com/grafana/grafana |
| node_exporter | `prom/node-exporter:latest` | `enable_node_exporter` | https://github.com/prometheus/node_exporter |
| cAdvisor | `gcr.io/cadvisor/cadvisor:latest` | `enable_cadvisor` | https://github.com/google/cadvisor |
| OpenObserve | `public.ecr.aws/zinclabs/openobserve:latest` | `enable_openobserve` | https://github.com/openobserve/openobserve |
| OpenTelemetry Collector (contrib) | `otel/opentelemetry-collector-contrib:latest` | `enable_otel` | https://github.com/open-telemetry/opentelemetry-collector-contrib |
| blackbox_exporter | `prom/blackbox-exporter:latest` | `enable_blackbox` | https://github.com/prometheus/blackbox_exporter |
| Heimdall | `lscr.io/linuxserver/heimdall:latest` | `enable_heimdall` | https://github.com/linuxserver/Heimdall |
| Uptime Kuma | `louislam/uptime-kuma:1` | `enable_uptime_kuma` | https://github.com/louislam/uptime-kuma |
| Traefik | `traefik:v3.1` | `enable_traefik` | https://github.com/traefik/traefik |
| statsd_exporter | `prom/statsd-exporter:latest` | `enable_statsd_exporter` | https://github.com/prometheus/statsd_exporter |
| ssh_exporter | `treydock/ssh_exporter:latest` | `enable_ssh_exporter` | https://github.com/treydock/ssh_exporter |
| Vector | `timberio/vector:latest-debian` | `enable_vector` | https://github.com/vectordotdev/vector |

## k0s host — exporter binaries

Installed by the shared `install-exporter.sh` helper, which downloads a GitHub release and registers a
systemd unit. The `{ARCH}` placeholder in each URL is substituted with `arm64`/`amd64` (from `dpkg`),
so the bundle works on Apple-Silicon Multipass and amd64 Proxmox alike.

| Exporter | Version | Gated by | Release |
|----------|---------|----------|---------|
| node_exporter | `v1.8.2` | `enable_node_exporter` | [releases](https://github.com/prometheus/node_exporter/releases/tag/v1.8.2) |
| process-exporter | `v0.8.4` | `enable_process_exporter` | [releases](https://github.com/ncabatoff/process-exporter/releases/tag/v0.8.4) |
| cAdvisor | `v0.49.1` | `enable_cadvisor` | [releases](https://github.com/google/cadvisor/releases/tag/v0.49.1) |
| filestat_exporter | `v0.4.5` | `enable_filestat_exporter` | [releases](https://github.com/michael-doubez/filestat_exporter/releases/tag/v0.4.5) |
| nut_exporter | `v3.2.5` | `enable_nut_exporter` (off) | [releases](https://github.com/DRuggeri/nut_exporter/releases/tag/v3.2.5) |
| nftables_exporter | `2.1.0` | `enable_nftables_exporter` (off) | [releases](https://github.com/Sheridan/nftables_exporter/releases/tag/2.1.0) |
| osquery_exporter | `v0.1.1` | `enable_osquery_exporter` (off) | [releases](https://github.com/zwopir/osquery_exporter/releases/tag/v0.1.1) |
| ebpf_exporter | `v2.4.2` | `enable_ebpf_exporter` (off) | [releases](https://github.com/cloudflare/ebpf_exporter/releases/tag/v2.4.2) |
| texporter | `v0.1.0` | `enable_texporter` (off) | [releases](https://github.com/wobcom/texporter/releases/tag/v0.1.0) |
| ffmpeg_exporter | `v0.1.0` | `enable_ffmpeg_exporter` (off) | [releases](https://github.com/projectkudu/ffmpeg_exporter/releases/tag/v0.1.0) |
| script_exporter | `v2.18.0` | `enable_script_exporter` (off) | [releases](https://github.com/ricoberger/script_exporter/releases/tag/v2.18.0) |
| netdata | latest (kickstart) | `enable_netdata` | [get.netdata.cloud](https://get.netdata.cloud/) · [repo](https://github.com/netdata/netdata) |

> Some of the off-by-default exporter release URLs may need version bumps over time (upstream tags
> move/disappear). If a target shows `down`, check the install block in
> [`k0s-client.yaml.tftpl`](../cloud-init/k0s-client.yaml.tftpl).

## Kubernetes components

| Component | Version | Source |
|-----------|---------|--------|
| k0s | latest (via [get.k0s.sh](https://get.k0s.sh)) | https://github.com/k0sproject/k0s |
| kube-state-metrics | `registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.13.0` | https://github.com/kubernetes/kube-state-metrics |

k0s runs as a single node (`controller --single`) with the kubelet **read-only port 10255** enabled
via `--kubelet-extra-args`. kube-state-metrics runs as a **hostNetwork Deployment** (binding the host's
`:8081`) authenticated with the k0s admin kubeconfig — a ClusterIP Service would be unreachable from
the server.

## OS packages & install scripts

Installed via cloud-init on both VMs (Ubuntu `24.04`):

| Host | apt packages | Install scripts |
|------|--------------|-----------------|
| server | `curl`, `vim`, `htop`, `jq` | Docker — `https://get.docker.com` |
| k0s | `curl`, `tar`, `vim`, `htop`, `jq` | k0s — `https://get.k0s.sh`; netdata — `https://get.netdata.cloud/kickstart.sh` |

Conditional apt installs on the k0s host (only when their flag is on): `osquery`
(`enable_osquery_exporter`), `ffmpeg` (`enable_ffmpeg_exporter`), and
`linux-headers-$(uname -r)` / `linux-headers-generic` (`enable_ebpf_exporter` or `enable_texporter`).

## Test toolchain

Live tests under [`tests/testinfra/`](../tests/testinfra/) (managed by `uv`):

| Tool | Purpose | Upstream |
|------|---------|----------|
| pytest | test runner | https://github.com/pytest-dev/pytest |
| pytest-testinfra | assert over SSH against running VMs | https://github.com/pytest-dev/pytest-testinfra |

Hermetic tests use OpenTofu's native `tofu test` with `mock_provider "multipass" {}` — no extra
dependency. See [operations.md](operations.md#testing).
