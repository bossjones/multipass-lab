# Spec: Centralized Logging Cluster

## Context

`multipass-lab` prototypes homelab infrastructure with OpenTofu + Multipass before promoting
it to Proxmox. This is the **first cluster** — a centralized-logging stand-in for the real
goal: shipping UniFi/Ubiquiti and host logs to one collector. It is an MVP built around
**syslog-ng** as the shipper, chosen deliberately because VictoriaLogs and OpenObserve both
ingest RFC5424 syslog — so the shipper layer stays reusable when the central sink is swapped
later.

Each cluster is **vendored to its own folder** (`clusters/centralized_logging/`). One
`tofu apply` brings up three Multipass VMs; a root `Justfile` orchestrates by cluster name.

## Objective

`just up centralized_logging` provisions 3 Multipass VMs via OpenTofu:

1. **central** — syslog-ng **server**; receives logs over TCP/RFC5424 and writes them to
   `/var/log/remote/<host>/<program>.log` (a pluggable sink).
2. **k0s-client** — syslog-ng client + single-node k0s cluster.
3. **docker-client** — syslog-ng client + Docker stack (Traefik, Heimdall, Grafana,
   Prometheus, Alertmanager).

Every VM ships as much as possible (journald via `system()` + syslog-ng `internal()`) to
`central` over TCP with reliable on-disk buffering, so logs survive central downtime.

## Architecture

```
        ┌─────────────────────────┐
        │ centralized-logging-k0s │  syslog-ng client ─┐
        │  k0s --single           │                    │  RFC5424 / TCP:514
        └─────────────────────────┘                    │  disk-buffer(reliable)
                                                        ▼
        ┌────────────────────────────┐        ┌──────────────────────────────┐
        │ centralized-logging-docker │ ─────▶  │ centralized-logging-central  │
        │  docker stack (journald)   │         │  syslog-ng server            │
        └────────────────────────────┘         │  /var/log/remote/<host>/...  │
                                                └──────────────────────────────┘
                                                  (future: VictoriaLogs / OpenObserve)
```

### Resource sizing

| VM | vCPU | RAM | Disk | Why |
|----|------|-----|------|-----|
| central | 2 | 2G | **40G** | disk-heavy: holds collected logs |
| k0s-client | 2 | 2G | 20G | k0s controller+worker single node |
| docker-client | 2 | 4G | 25G | Grafana + Prometheus + Traefik + Heimdall + Alertmanager |
| **total** | **6** | **8G** | **85G** | comfortable on a 16G+ host |

### Provider & IP injection (the key mechanism)

- Provider: [`larstobi/multipass`](https://registry.terraform.io/providers/larstobi/multipass)
  (`~> 1.4`, public registry — `tofu init` fetches it). `multipass_instance` exposes
  `name`, `image`, `cpus`, `memory`, `disk`, `cloudinit_file` (a **file path**), and a computed
  `ipv4`. No bridged networking — VMs reach each other on the Multipass subnet by IP.
- Multipass hands out DHCP IPs, so the central IP can't be hardcoded. OpenTofu:
  1. creates `central` first,
  2. reads its computed `ipv4`,
  3. renders each client's cloud-init from a `templatefile()` into a `local_file`,
  4. points the client `multipass_instance.cloudinit_file` at that rendered file.

  The implicit dependency graph (client → `local_file` → `central.ipv4` → central instance)
  orders this correctly inside a single `tofu apply`.

### Log shipping

- **Clients** (`cloud-init/syslog-ng/client.conf.tftpl`): `system()` + `internal()` sources →
  `network()` destination to `<central_ip>:514`, `transport(tcp)`, `flags(syslog-protocol)`
  (RFC5424), `disk-buffer(reliable(yes), disk-buf-size 512MiB, mem-buf-size ~160MiB)` and
  `flags(flow-control)` on the log path — reliability + backpressure for "ship as many logs as
  possible" without dropping under load.
- **Central** (`cloud-init/syslog-ng/server.conf.tftpl`): `network(transport(tcp) port(514)
  max-connections(100))` source → `file("/var/log/remote/$HOST/$PROGRAM.log" create-dirs(yes))`.
  How `$HOST` resolves for remote senders is set by `var.hostname_source` (see below). A
  commented stub shows how to add a VictoriaLogs/OpenObserve destination later (additive).

### Hostname foldering (`var.hostname_source`)

Central folders received logs as `/var/log/remote/$HOST/$PROGRAM.log`. `$HOST` for remote
senders is controlled by `hostname_source` (default **`keep`**):

| value | syslog-ng options | result |
|-------|-------------------|--------|
| `keep` (default) | `keep-hostname(yes)` | trust the client's self-reported hostname (e.g. `centralized-logging-k0s`). **DNS-independent.** |
| `dns` | `keep-hostname(no) use-dns(yes) use-fqdn(no)` | reverse-resolve the sender IP; **needs PTR records** (falls back to raw IP otherwise). |
| `ip` | `keep-hostname(no) use-dns(no)` | fold by raw sender IP. |

`keep` is the default because homelab DNS is unreliable and this lab has no PTR records, so
`dns` would currently fold by IP anyway. Only the central server config changes with this
variable — clients already transmit their hostname in the RFC5424 message. Switch modes by
setting `hostname_source` and re-provisioning (see Notes on applying cloud-init changes).
- **Capturing container/service logs**: the docker-client sets Docker's daemon
  `log-driver: journald`; the k0s-client's k0s/containerd services log to journald. syslog-ng's
  `system()` source reads journald, so those logs flow to central without per-container config.

## Layout

```
multipass-lab/
├── Justfile                                   # root orchestrator (cluster arg)
├── specs/centralized_logging.md               # this document
└── clusters/centralized_logging/
    ├── versions.tf  providers.tf  variables.tf  terraform.tfvars
    ├── main.tf      outputs.tf     README.md
    ├── cloud-init/
    │   ├── central.yaml.tftpl  k0s-client.yaml.tftpl  docker-client.yaml.tftpl
    │   ├── syslog-ng/{server,client}.conf.tftpl
    │   └── docker/compose.yaml.tftpl
    ├── tests/tofu/sizing_and_render.tftest.hcl     # Layer 0/1 hermetic (mock_provider)
    └── tests/testinfra/                            # Layer 2 live verify (pytest+testinfra/SSH)
        ├── pyproject.toml  conftest.py
        └── test_central.py  test_clients.py  test_e2e_shipping.py
```

## Testing — layered feedback loop

Mirrors the `boss-skills/specs` philosophy (`terraform-plan.md`, `ansible-dev-plugin.md`):
a hermetic inner loop, then a live "real machine" rung verified with **pytest + testinfra**.

- **Layer 0/1 — hermetic (`just check`, no VMs)**: `tofu fmt -check`, `tofu validate`, and
  `tofu test -test-directory=tests/tofu` using `mock_provider "multipass"` (plan-only). Asserts
  sizing/image/names from tfvars and that the central rendered cloud-init carries the syslog-ng
  server config + injected key. Fast; mutates nothing.
- **Layer 2 — live verify (`just verify`, after `just up`)**: `uv run pytest` in
  `tests/testinfra`. `conftest.py` reads `tofu output -json` and builds `ssh://ubuntu@<ip>`
  testinfra hosts (key injected via cloud-init). Per role:
  - central: syslog-ng running/enabled, TCP:514 listening, `/var/log/remote` exists.
  - k0s-client: syslog-ng running, disk-buffer dir present, `k0s status` healthy.
  - docker-client: docker active, all 5 compose services running, daemon log-driver journald.
  - **E2E (headline)**: `logger -t e2e <uuid>` on each client → poll central until `<uuid>`
    appears under `/var/log/remote/<host>/`.

## Quickstart

```sh
just check centralized_logging    # hermetic
just up centralized_logging       # one apply -> 3 VMs
multipass list                    # 3 Running with IPs
just verify centralized_logging   # syslog-ng / k0s / docker / E2E shipping
just logs centralized_logging     # list collected log files on central
just down centralized_logging     # destroy
```

Requires OpenTofu ≥ 1.7, `multipass`, `uv`, `just`, and an SSH keypair at
`~/.ssh/id_ed25519[.pub]`.

## Applying cloud-init / config changes

The `larstobi/multipass` provider keys `multipass_instance` on the `cloudinit_file` **path**,
not its content — so editing a cloud-init template (e.g. changing `hostname_source`) updates the
rendered `.rendered/*.yaml` but does **not** recreate the VM on `tofu apply`. Recreating central
alone would also change its DHCP IP and break the clients' baked `central_ip`. To apply config
changes, recreate the whole cluster: `just down centralized_logging && just up centralized_logging`.

## Future work (kept in mind, not built here)

- **Auto-recreate on cloud-init change**: add `lifecycle { replace_triggered_by = [
  local_file.*.content_sha256 ] }` to the instances so `just up` rebuilds VMs when their
  cloud-init changes (clients must also re-render against central's new IP) — removes the manual
  `down`/`up` step above.

- **Swap the central sink** to VictoriaLogs or OpenObserve (both ingest RFC5424) — add one
  `log {}`/destination block in `server.conf.tftpl`; clients are unchanged.
- **Promote to Proxmox** via Ansible roles — the same syslog-ng configs apply, and the
  testinfra suite carries over to the Ansible/Proxmox rung unchanged (cloud-init key + SSH).
- **Primary real use case**: shipping UniFi/Ubiquiti logs to this collector.
