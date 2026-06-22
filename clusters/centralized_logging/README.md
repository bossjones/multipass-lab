# centralized_logging cluster

Three Multipass VMs provisioned by OpenTofu, demonstrating centralized log shipping
with syslog-ng. See [`../../specs/centralized_logging.md`](../../specs/centralized_logging.md)
for the full design.

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
