# centralized_dns

A single Multipass VM providing **network-wide DNS** for the lab:

```
fleet VMs ─► AdGuard Home (0.0.0.0:53) ─► Unbound (127.0.0.1:5335) ─► root DNS
             ad/tracker blocking          recursive + DNSSEC
             UI/API :3000                  control socket -> unbound_exporter
```

Both AdGuard Home and Unbound run **host-level under systemd** (no Docker), mirroring the
`adguardhome-unbound-macos-setup` reference (LaunchDaemons → systemd units). Full design:
[`specs/centralized_dns.md`](../../specs/centralized_dns.md).

## What runs on the VM

| Component | Bind | Systemd unit | Notes |
|---|---|---|---|
| AdGuard Home | `0.0.0.0:53` (DNS), `:3000` (UI/API) | `AdGuardHome.service` | pre-seeded config → no setup wizard |
| Unbound | `127.0.0.1:5335` | `unbound.service` | hardened, DNSSEC, `/run/unbound.ctl` control socket |
| adguard-exporter | `:9618` | `adguard-exporter.service` | Grafana dashboard 20799 |
| unbound_exporter | `:9167` | `unbound_exporter.service` | reads the Unbound control socket |
| node_exporter | `:9100` | `node_exporter.service` | OS host metrics |
| process/systemd exporter | `:9256` / `:9558` | (flagged) | per-process / per-unit metrics |

## Quick start

```sh
just check centralized_dns    # hermetic (no VMs): fmt + validate + tofu test
just up    centralized_dns    # launch the VM
just verify centralized_dns   # live testinfra over SSH
just verify-api centralized_dns  # adguard + unbound host-side `check`
just open  centralized_dns    # AdGuard Home UI in the browser (--full adds /metrics)
```

## Role in the fleet

`centralized_dns` is a **cross-cluster hub that comes up first** in `just up-connected`: every
other VM (both telemetry hubs and all consumers) points `systemd-resolved` at this AdGuard Home
instance at first boot (the shared `dns_server` opt-in var; see
[`specs/cross-cluster.md`](../../specs/cross-cluster.md)). Its own logs ship to
`centralized_monitoring`'s OpenObserve and its exporters are scraped by Prometheus — both wired by
a post-boot hot-push so the DNS VM (and the IP the fleet resolves against) is never recreated.

## Feature flags

`enable_node_exporter`, `enable_adguard_exporter`, `enable_unbound_exporter`,
`enable_process_exporter`, `enable_systemd_exporter` (all default **on**). Cross-cluster opt-ins
(`dns_server`, `log_shipping_target`, `openobserve_endpoint`) default empty — a plain
`just up centralized_dns` is turnkey and isolated.

## HA mode (opt-in `enable_ha`)

Off by default — the single VM above, unchanged. `enable_ha = true` (+ `vip_address`) instead
brings up two self-contained nodes, `primary` and `secondary`, each running its own AdGuard Home +
Unbound + exporters (no shared upstream), fronted by a **keepalived** unicast-VRRP floating VIP.
The whole fleet resolves DNS through the VIP; killing AdGuard (or the VM) on the node holding the
VIP moves it to the healthy node in a few seconds. **AdGuardHome-Sync** replicates config
(blocklists, rewrites, filtering, settings) unidirectionally `primary → secondary` on a timer, so
**config edits must only ever be made on `primary`'s UI/API** — `secondary` is overwritten on
every sync cycle. Full design, the OpenTofu resource shape (and why the singleton `server` VM and
the HA `primary`/`secondary` nodes are kept as separate resources rather than unified into one
`for_each`), and the peer-IP wiring are in [`specs/ha-dns.md`](../../specs/ha-dns.md).

```sh
just recreate centralized_dns          # after setting enable_ha=true / vip_address (needs recreate, not up)
just verify centralized_dns            # HA-aware; adds keepalived + sync + failover tests
just dns-failover-test centralized_dns # kill AdGuard on the VIP holder, assert it moves + preempts back
just dns-sync-status centralized_dns   # AdGuardHome-Sync status on primary
```

New outputs `dns_endpoint` (the VIP in HA mode, the single VM's IP otherwise — what the fleet
resolves against) and `dns_rewrite_target` (the origin node — where `just set-dns-all` pushes
rewrites) are what every other cluster/recipe reads, so HA needs no mode-specific branching
elsewhere in the fleet.
