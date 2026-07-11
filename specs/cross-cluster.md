# Cross-cluster telemetry

Status: **implemented** · Reference consumer: `centralized_pki` · Hubs: `centralized_logging`
(collector), `centralized_monitoring` (scraper + self-shipper)

## Problem

Every cluster under `clusters/` is a **fully self-contained OpenTofu root module** — its own state, its
own cloud-init, no shared module and no cross-references. `centralized_logging` runs a syslog-ng
collector and `centralized_monitoring` runs Prometheus/Grafana/OpenObserve, but each only observes **its
own VMs**. A VM in `centralized_pki` (or any future cluster) cannot ship its logs to the logging hub or
be scraped by the monitoring hub. For self-contained agentic development we want any cluster to opt into
being a **log-shipper** and a **scrape-target** by flipping feature flags, plus one orchestrator that
brings the whole fleet up already wired together.

The hard part is **not** connectivity. Every VM lands on the same flat Multipass `/24` (e.g.
`192.168.252.0/24`) and every collector/exporter binds `0.0.0.0`, so a VM in cluster A can already reach
a service in cluster B by IP. The two missing pieces are:

1. **Cross-state IP discovery** — a cluster's `main.tf` can only reference `multipass_instance` resources
   in its *own* state, so it has no way to learn a peer cluster's DHCP IP.
2. **Opt-in cloud-init wiring** — consumer VMs need a syslog-ng client + an OTLP agent, gated behind
   feature flags so the default `just up <cluster>` stays turnkey and isolated.

## Directionality (the crux)

The three signal paths flow in **two opposite directions**, which dictates the apply ordering:

| Signal | Model | Who needs whose IP | Hub change |
|---|---|---|---|
| DNS → AdGuard Home | **config-PUSH** | *every* VM needs the *DNS hub* IP at first boot | none (already listens `0.0.0.0:53`) |
| Logs → syslog-ng | **PUSH** | consumer needs the *logging hub* IP | none (already listens `0.0.0.0:514`) |
| Logs/traces → OpenObserve/OTLP | **PUSH** | consumer needs the *monitoring hub* IP | none (OpenObserve `:5080`, OTel `:4318`) |
| Metrics ← Prometheus | **PULL** | the *monitoring hub* needs every consumer IP | new `extra_scrape_targets` var |

### DNS: the hub that must come up FIRST (`centralized_dns`)

`centralized_dns` (AdGuard Home over Unbound; see `specs/centralized_dns.md`) is a fourth signal
with the strongest ordering constraint. Every VM in the fleet — including both telemetry hubs —
must know the DNS hub IP **at its own first boot** so it can point `systemd-resolved` at AdGuard
via the shared `use-dns.conf.tftpl` drop-in. Like the telemetry hubs it is a pure sink (it needs
nobody's IP to come up), so `up-connected` applies it **before everything else**, health-gates on
AdGuard actually answering (`dig @<dns_ip> example.com`) — a dependent VM that switches its
resolver before AdGuard is live can't resolve `archive.ubuntu.com` mid-boot — then wires every
later cluster with `dns_server=<dns_ip>`.

`<dns_ip>` here is `centralized_dns`'s `dns_endpoint` output, not `server_ipv4` — with the
opt-in HA mode (`enable_ha`; see `specs/ha-dns.md`), `dns_endpoint` resolves to the floating
keepalived VIP fronting `primary`/`secondary` instead of a single VM's IP, so `up-connected`'s
health-gate and every consumer's `dns_server` wiring need no HA-mode branching — they always
read `dns_endpoint`. DNS-record pushes (`just set-dns-all`) instead target `dns_rewrite_target`
(the origin/`primary` node in HA mode, so AdGuardHome-Sync replicates to `secondary`; the single
VM otherwise) — pushing at the VIP would race the next sync cycle.

The DNS hub is *also* a telemetry consumer (its own logs → OpenObserve, its exporters scraped by
Prometheus), but it booted **before** the telemetry hubs existed. This is resolved exactly like
the Prometheus scrape-target problem: its own log-shipping is **hot-pushed** after the hubs come
up (`up-connected` sets its `log_shipping_target`/`openobserve_endpoint`, re-applies to materialize
the rendered drop-ins, then scp's them onto the running VM and restarts the agents — no recreate,
so the DNS IP the whole fleet resolves against never churns), and its exporters (`:9100`, `:9618`,
`:9167`) are added to the same `extra_scrape_targets` hot-push.

The full apply order is therefore: `centralized_dns → centralized_logging → centralized_monitoring
→ consumers → hot-push (DNS self-telemetry + Prometheus scrape targets)`.

The two **PUSH** paths make both hubs pure *sinks* — they receive on a fixed port and need nobody's IP
to come up. Only the **PULL** path (Prometheus scraping consumers) needs consumer IPs, and that need is
met **without** re-ordering the hub: the discovered targets are **hot-pushed** into the already-running
Prometheus (scp the re-rendered `prometheus.yml` + restart the container), never recreating the
monitoring VM. So the implemented apply order brings **both hubs up first**, then every consumer boots
already knowing both hub IPs and wires all three signals in a single boot (stable IPs, no recreate). This
also resolves the apparent logging↔monitoring cycle: logging comes up first, so the monitoring hub can
ship its *own* OS logs there at its own first boot (`log_shipping_target`).

```
apply order:  centralized_logging  →  centralized_monitoring  →  consumer clusters  →  hot-push scrape targets
              (pure sink, first)      (OTLP/OpenObserve sink;      (get BOTH hub IPs      (scp prometheus.yml +
                                       ships its own logs)          at first boot)         restart; no recreate)
```

> **Note (design divergence from the first draft).** An earlier version of this spec applied the
> monitoring hub **last** (`logging → consumers → monitoring`) and required an OpenObserve *second pass*
> that rewrote each consumer's `openobserve_endpoint` and `just recreate`d it once the hub IP was known.
> The shipped implementation instead brings the monitoring hub up **second** — because it's a sink, it
> needs no consumer IP to boot — so consumers learn both hub IPs at first boot and the second pass is
> gone. Scrape targets are hot-pushed post-apply (§ Orchestration). The sections below describe the
> **implemented** design.

## Discovery mechanism: `.cross-cluster.auto.tfvars.json`

`just up-connected` performs the ordered apply and, before each `just up <name>`, writes the discovered
peer IPs to `clusters/<name>/.cross-cluster.auto.tfvars.json`. OpenTofu auto-loads `*.auto.tfvars.json`,
so the values reach the module with no `-var` juggling, no `TF_VAR_` env, and no
`terraform_remote_state`. The file is **gitignored and generated** (same spirit as `.rendered/`).

Example written for `centralized_pki`:

```json
{
  "log_shipping_target": "192.168.252.12:514",
  "openobserve_endpoint": "192.168.252.33:5080"
}
```

The `centralized_monitoring` file is written **twice**: first with just `log_shipping_target` (before the
hub boots, so it self-ships its OS logs), then rewritten to *add* `extra_scrape_targets` once consumer
IPs are known (the hot-push re-apply — see § Orchestration):

```json
{
  "log_shipping_target": "192.168.252.12:514",
  "extra_scrape_targets": [
    { "job": "centralized-pki-ca",       "ip": "192.168.252.20", "port": 9100 },
    { "job": "centralized-pki-services", "ip": "192.168.252.21", "port": 9100 }
  ]
}
```

Peer IPs come from the hubs' existing outputs — `centralized_logging.central_ipv4`,
`centralized_monitoring.server_ipv4` — and consumer IPs from each cluster's `hosts` output
(`role → {name, ipv4}`).

### No second pass: hub-second boot + hot-pushed scrape targets

Because both hubs are sinks, `up-connected` brings the monitoring hub up **second** (right after
logging), so every consumer boots already knowing `openobserve_endpoint=<server_ip>:5080` and wires all
three signals — syslog shipping, OTLP push, and `node_exporter` scrape exposure — in a **single boot**.
No consumer is ever recreated. The one remaining edge (Prometheus needs the consumer IPs it can't know
until they boot) is closed **without** touching the monitoring VM: after all consumers are up,
`up-connected` sets `extra_scrape_targets`, re-applies the monitoring root to re-render `prometheus.yml`
(a cloud-init content change never recreates a `multipass_instance`), then scp's that file onto the
running server and restarts only the Prometheus container. Keeping the monitoring VM stable is what lets
consumers push OTLP to an IP that never churns.

## Standard variable contract

Any cluster that opts into cross-cluster telemetry declares these (defaults keep `just up` turnkey and
isolated — empty string = feature off):

| Variable | Type | Default | Effect |
|---|---|---|---|
| `dns_server` | string | `""` | IP (or `host[:port]`) of the `centralized_dns` AdGuard Home resolver. Non-empty → every VM renders `/etc/systemd/resolved.conf.d/99-centralized-dns.conf` (shared `use-dns.conf.tftpl`) and repoints `systemd-resolved` at it at first boot. |
| `log_shipping_target` | string | `""` | `host:port` of syslog-ng collector. Non-empty → VMs render the syslog client drop-in shipping to it. |
| `openobserve_endpoint` | string | `""` | `host:port` of OpenObserve. Non-empty → VMs run an otelcol-contrib agent pushing host logs. |
| `openobserve_org` | string | `"default"` | OpenObserve org in the OTLP push URL. |
| `openobserve_password` | string (sensitive) | dev default | OpenObserve root password for the OTLP `Basic` auth header. |
| `enable_node_exporter` | bool | `true` | Exposes `:9100` so the monitoring hub can scrape (already present in most clusters). |

The monitoring hub additionally declares `extra_scrape_targets`, and — because it too is just another VM
on the flat subnet — also opts into `log_shipping_target` to ship its **own** OS logs to the logging hub
(it renders the same shared syslog-ng client drop-in as any consumer):

| Variable | Type | Default | Effect |
|---|---|---|---|
| `extra_scrape_targets` | `list(object({ job=string, ip=string, port=optional(number,9100) }))` | `[]` | Each entry becomes one static-config Prometheus job scraping a cross-cluster VM. |
| `netdata_scrape_targets` | `list(object({ name=string, ip=string }))` | `[]` | Each entry is folded into the single `job="netdata"` (scraped at `:19999` `/api/v1/allmetrics?format=prometheus`, `honor_labels`) with `name` as the instance label. See `specs/shared-netdata.md`. |
| `log_shipping_target` | string | `""` | `host:port` of the syslog-ng collector. Non-empty → the server VM ships its own OS logs there (hub-as-log-shipper; logging is applied first so the IP is known). |

## Shared snippets: `clusters/_shared/cloud-init/`

The syslog client conf and OTLP agent config **must stay byte-identical** across clusters, so they live
in a new `clusters/_shared/cloud-init/` referenced by each cluster's `templatefile()` — a **deliberate,
documented exception** to the strict per-cluster vendoring rule. The `_shared` underscore prefix marks it
as a non-cluster directory; Justfile recipes that iterate `clusters/*/` (`up-all`, `destroy-all`,
`verify-all`, `verify-api`, `prune`) skip any directory without a `main.tf`.

| Snippet | Params | Derived from |
|---|---|---|
| `use-dns.conf.tftpl` | `dns_ip` | new — `resolved.conf.d` drop-in pointing at the `centralized_dns` AdGuard hub |
| `syslog-client.conf.tftpl` | `central_ip`, `syslog_port` | `centralized_logging/cloud-init/syslog-ng/client.conf.tftpl` |
| `otel-agent-config.yaml.tftpl` | `openobserve_ip`, `openobserve_port`, `openobserve_org`, `openobserve_password`, `stream_name` | `centralized_monitoring/cloud-init/otel/k0s-collector-config.yaml.tftpl` |
| `install-node-exporter.sh` | — (arch-aware) | `centralized_monitoring`'s `install-exporter.sh` |
| `install-netdata.sh.tftpl` | `host_labels` (`{cluster,role,environment}`), `enable_ebpf` | new — fleet-wide Netdata agent installer (`:19999`, Prometheus endpoint) tuned for max stats; replaced the per-cluster inline kickstart. Gated by `enable_netdata` (default on). See `specs/shared-netdata.md`. |

## Orchestration

```sh
just up-connected      # logging → monitoring → consumers, all wired at first boot; scrape targets hot-pushed
just verify-connected  # live e2e: pki log line reaches the hub; Prometheus scrapes pki targets
```

`up-connected` reuses the existing `up` glob + cloud-init SSH wait loop and the `tr '_' '-'` folder→VM
name mapping. `verify-connected` reuses the `test_e2e_shipping.py` idiom (`logger` on a consumer VM →
grep `/var/log/remote/` on the logging central) and `prometheus_cli.py targets` against the monitoring
server.

The consumer loop tracks a per-cluster `rc` (mirroring `up-all`) and prints a `FAILED consumer: <c>`
line + nonzero exit on any failure, so a broken consumer bring-up is loud instead of silent. Bulk
bring-up also enables the heavier opt-in features that change cloud-init (so they must be set at first
apply): `up-connected` writes `enable_coroot=true` into the logging hub's `.cross-cluster.auto.tfvars.json`
and `enable_discovery=true` into netbox's; `up-all` drops a small `<cluster>/.flags.auto.tfvars.json`
for the same two (both gitignored).

### DNS record registration — the final step

As its **last** step (after the Prometheus scrape-target hot-push), `up-connected` runs `just
set-dns-all`, which merges every up cluster's `dns_records` output and syncs them into
`centralized_dns`'s AdGuard as idempotent rewrites (`adguard_cli.py rewrite-sync`). This is why it runs
dead last: each cluster's `dns_records` needs its VMs' DHCP IPs, so the whole fleet must be up first.
After that, `grafana.<domain>` / `netbox.<domain>` / `auth.<domain>` / … resolve fleet-wide — no
`/etc/hosts` edits. `just verify-dns` `dig`s each record against the AdGuard IP. See
`specs/centralized_dns.md` §7a for the CLI + per-cluster `dns_records`/`domain` contract.

## Testing

Two-layer split, mirroring the rest of the repo:

- **Hermetic** (`just check <cluster>`) — `mock_provider "multipass"` + `command = plan`. With
  `log_shipping_target` set, assert the rendered cloud-init contains `d_central` and the IP; with `""`,
  assert it does not. Mirror for `openobserve_endpoint`, and for the monitoring hub assert both that
  `extra_scrape_targets` render into `prometheus.yml` **and** that a non-empty `log_shipping_target`
  renders the server VM's own syslog-ng drop-in (hub self-shipping).
- **Live** (`just verify-connected`) — end-to-end log delivery + scrape confirmation against running VMs.

## Rollout

`centralized_pki` is the reference consumer (it already installs `node_exporter` on both VMs, so only the
log-shipping and OTLP-push paths are net-new there). Other clusters replicate the pattern by adding the
standard variables, referencing the `_shared/` snippets, and dropping the gated `write_files`/`runcmd`
blocks into their VM cloud-init.

## Future work

- **`file_sd`/`http_sd` for Prometheus** — replace the static `extra_scrape_targets` re-apply with a
  targets JSON pushed to the server (hot reload, no re-apply). The `k0s_log_shipper` post-apply
  provisioner is the precedent.
- **NetBox as source of truth** — have every VM self-register into `centralized_netbox` (its "Future
  work" note) and drive `http_sd` from the NetBox API, eliminating the `.auto.tfvars.json` handoff.

## See also

`specs/dynamic-traefik.md` applies this same discover-render-hot-push shape to reverse-proxy
routing: `traefik_cli.py` aggregates a `reverse_proxy_routes` output (mirroring this doc's
`metrics_targets`/`hosts` outputs) across clusters and hot-pushes a Traefik `fleet.yaml` onto
`centralized_pki`'s services VM — same `scp` + `ssh cp`, no restart, no recreate idiom as the
`prometheus.yml` push in `up-connected` §5.
