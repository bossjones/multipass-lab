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
| Logs → syslog-ng | **PUSH** | consumer needs the *logging hub* IP | none (already listens `0.0.0.0:514`) |
| Logs/traces → OpenObserve/OTLP | **PUSH** | consumer needs the *monitoring hub* IP | none (OpenObserve `:5080`, OTel `:4318`) |
| Metrics ← Prometheus | **PULL** | the *monitoring hub* needs every consumer IP | new `extra_scrape_targets` var |

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
| `log_shipping_target` | string | `""` | `host:port` of the syslog-ng collector. Non-empty → the server VM ships its own OS logs there (hub-as-log-shipper; logging is applied first so the IP is known). |

## Shared snippets: `clusters/_shared/cloud-init/`

The syslog client conf and OTLP agent config **must stay byte-identical** across clusters, so they live
in a new `clusters/_shared/cloud-init/` referenced by each cluster's `templatefile()` — a **deliberate,
documented exception** to the strict per-cluster vendoring rule. The `_shared` underscore prefix marks it
as a non-cluster directory; Justfile recipes that iterate `clusters/*/` (`up-all`, `destroy-all`,
`verify-all`, `verify-api`, `prune`) skip any directory without a `main.tf`.

| Snippet | Params | Derived from |
|---|---|---|
| `syslog-client.conf.tftpl` | `central_ip`, `syslog_port` | `centralized_logging/cloud-init/syslog-ng/client.conf.tftpl` |
| `otel-agent-config.yaml.tftpl` | `openobserve_ip`, `openobserve_port`, `openobserve_org`, `openobserve_password`, `stream_name` | `centralized_monitoring/cloud-init/otel/k0s-collector-config.yaml.tftpl` |
| `install-node-exporter.sh` | — (arch-aware) | `centralized_monitoring`'s `install-exporter.sh` |

## Orchestration

```sh
just up-connected      # logging → monitoring → consumers, all wired at first boot; scrape targets hot-pushed
just verify-connected  # live e2e: pki log line reaches the hub; Prometheus scrapes pki targets
```

`up-connected` reuses the existing `up` glob + cloud-init SSH wait loop and the `tr '_' '-'` folder→VM
name mapping. `verify-connected` reuses the `test_e2e_shipping.py` idiom (`logger` on a consumer VM →
grep `/var/log/remote/` on the logging central) and `prometheus_cli.py targets` against the monitoring
server.

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
