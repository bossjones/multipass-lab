# centralized_monitoring

Second cluster in `multipass-lab` — a 2-VM observability stack. A Prometheus / Grafana /
OpenObserve **server** *pulls* metrics, traces, and uptime from a fully-instrumented
single-node **k0s** host. Sibling to `centralized_logging`; see
[`specs/centralized_monitoring.md`](../../specs/centralized_monitoring.md) for the full design.

> 📚 **Full documentation:** [`docs/`](docs/) — [architecture](docs/architecture.md) ·
> [endpoints & ports](docs/endpoints.md) · [feature flags](docs/feature-flags.md) ·
> [open-source dependencies](docs/dependencies.md) · [operations & testing](docs/operations.md).

| VM | role | vCPU | RAM | Disk | what it runs |
|----|------|------|-----|------|--------------|
| `centralized-monitoring-server` | `server` | 4 | 8G | 40G | Prometheus, Alertmanager, Grafana, OpenObserve, OTel Collector, blackbox, Heimdall, Uptime Kuma, Traefik, statsd/ssh exporters |
| `centralized-monitoring-k0s` | `k0s` | 2 | 4G | 30G | single-node k0s + node/process/cadvisor/netdata/nut/nftables/filestat exporters + kube-state-metrics |

## Inverted IP injection (vs logging)

Logging **pushes** (clients → central); Prometheus **pulls** (server → client). So the runtime
IP edge flips: the **k0s-client is created first**, OpenTofu reads its DHCP `ipv4`, renders the
server's `prometheus.yml` from it, then launches the server. The dependency chain
`server → prometheus.yml → k0s.ipv4 → k0s` orders it inside one `tofu apply`.

## Feature flags

Every exporter / integration is an individual `enable_*` bool that gates **both** its cloud-init
install/compose block **and** its `prometheus.yml` scrape job. Defaults: **MVP + Reach ON,
Nice-to-have OFF**, with two Reach exceptions kept **off** because they are lab-hostile —
`enable_nut_exporter` (needs a real UPS/`upsd`) and `enable_nftables_exporter` (no portable binary
release). The Prometheus / Grafana / Alertmanager spine is always on. The `enabled_exporters`
output lists the active set and drives the live test suite. See [`variables.tf`](variables.tf) and
[`USAGE.md`](USAGE.md) for the full table.

## Quickstart

```sh
just check centralized_monitoring    # hermetic: tofu fmt + validate + test (no VMs)
just up centralized_monitoring       # one apply -> k0s first, then server scrapes it
multipass list                       # 2 Running with IPs
just verify centralized_monitoring   # services up / all Prometheus targets up / blackbox / grafana
just ssh centralized_monitoring server
just down centralized_monitoring     # destroy
```

Requires OpenTofu ≥ 1.7, `multipass`, `uv`, `just`, and an SSH keypair at
`~/.ssh/id_ed25519[.pub]` (injected via cloud-init for the testinfra verify loop).

## Applying config changes

The `larstobi/multipass` provider keys the instance on the cloud-init **file path**, not its
content — editing a template (e.g. `prometheus_scrape_interval`) re-renders `.rendered/*.yaml`
but does **not** recreate the VM. Recreating the k0s-client alone also changes its DHCP IP,
invalidating the scrape target the server baked in. To apply changes, recreate the whole cluster:
`just down centralized_monitoring && just up centralized_monitoring`.
