# centralized_logging cluster

Three Multipass VMs provisioned by OpenTofu, demonstrating centralized log shipping
with syslog-ng. See [`../../specs/centralized_logging.md`](../../specs/centralized_logging.md)
for the full design.

> 📘 **New here?** Read the full [**USAGE guide**](USAGE.md) — prerequisites, configuration
> reference, diagrams, log-shipping internals, and troubleshooting.

> 📚 **Full documentation:** [`docs/`](docs/) — [architecture](docs/architecture.md) ·
> [endpoints & ports](docs/endpoints.md) · [feature flags](docs/feature-flags.md) ·
> [open-source dependencies](docs/dependencies.md) · [operations & testing](docs/operations.md).

| VM | Role | Sizing |
|----|------|--------|
| `centralized-logging-central` | syslog-ng **server** → `/var/log/remote/<host>/<prog>.log` | 2 vCPU / 2G / 40G |
| `centralized-logging-k0s` | syslog-ng client + single-node k0s | 2 vCPU / 2G / 20G |
| `centralized-logging-docker` | syslog-ng client + Docker stack | 2 vCPU / 4G / 25G |

## Quickstart (from the repo root)

```sh
just check centralized_logging   # hermetic: fmt + validate + tofu test (no VMs)
just up centralized_logging      # one apply -> all 3 VMs
just verify centralized_logging  # pytest + testinfra over SSH against live VMs
just logs centralized_logging    # list collected log files on central
just down centralized_logging    # destroy
```

## Notes

- Requires an SSH keypair at `~/.ssh/id_ed25519[.pub]` (injected via cloud-init; used by
  the testinfra verify loop). Override with `-var ssh_pubkey_path=...` or `CLUSTER_SSH_KEY`.
- Clients learn the central VM's DHCP IP automatically: OpenTofu creates `central` first,
  reads its `ipv4`, and renders each client's cloud-init from it.
- Docker container logs flow to central because the daemon uses the `journald` log-driver
  and syslog-ng's `system()` source reads journald.
- `var.hostname_source` (`keep` default | `dns` | `ip`) controls how central folders remote
  senders under `/var/log/remote/<host>/`. `keep` trusts the client hostname (DNS-free); `dns`
  reverse-resolves (needs PTR). Changing it requires a full `just down` + `just up` (the
  provider keys on the cloud-init file path, not its content).
- **Metrics:** each VM exposes flag-gated Prometheus exporters (node/syslog-ng/systemd/process,
  +cAdvisor on docker/k0s, +kube metrics on k0s), bound to `0.0.0.0` for a *future*
  `centralized_monitoring` scrape — nothing scrapes them yet. See
  [USAGE §9](USAGE.md#9-metrics--exporter-layer) and the
  [metrics spec](../../specs/centralized_logging_metrics.md). `journald-exporter` is off by default
  (x86-64-only binary).

## More docs

- 📘 [`USAGE.md`](USAGE.md) — detailed how-to-use guide for this lab
- 📚 [`docs/`](docs/) — deep reference suite (architecture, endpoints, feature flags, dependencies, operations)
- 🧭 [`TUTORIAL.md`](TUTORIAL.md) — hands-on "stand up & verify the metrics layer" walkthrough
- 📐 [`../../specs/centralized_logging.md`](../../specs/centralized_logging.md) — full design
- 📊 [`../../specs/centralized_logging_metrics.md`](../../specs/centralized_logging_metrics.md) — metrics/exporter design
- 📚 [`../../docs/README.md`](../../docs/README.md) — repo documentation hub
