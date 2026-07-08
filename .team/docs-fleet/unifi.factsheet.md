# Fact sheet: centralized_unifi

**One-liner:** A version-exact simulation of a UniFi homelab's log plane — two VMs reproducing the
USG (rsyslog 5.8.11) forwarding syslog to the UCK Gen2 Controller (syslog-ng 3.28.1), with a
Prometheus exporter on the collector; no human dashboards, log-pipeline only.

**VMs:**
| VM role | Count | Sizing | Purpose |
|---|---|---|---|
| `controller` (`centralized-unifi-controller`) | 1 | 2 cpus, 2G memory, 20G disk | UCK Gen2 / collector — runs syslog-ng 3.28.1-2+deb11u2 (Debian bullseye, native arm64) in a container; receives the USG's forwarded logs into `/var/log/remote/<host>/<prog>.log`; also runs `brandond/syslog_ng_exporter` on `:9577` (when `enable_syslogng_exporter`) |
| `usg` (`centralized-unifi-usg`) | 1 | 2 cpus, 2G memory, 15G disk | USG / forwarder — runs rsyslog 5.8.11-3+deb7u2 (Debian wheezy, **emulated amd64** — wheezy has no arm64 port) in a container; forwards `*.debug;local7.debug` via UDP/514 to the controller's runtime-injected IP; also runs a traffic generator (when `enable_unifi_traffic`) |

Both VMs also run `node_exporter` on `:9100` (host-level, when `enable_node_exporter`).

**Existing docs (confirmed to exist on disk):**
- `clusters/centralized_unifi/README.md` (only cluster-level doc — no USAGE.md, no TUTORIAL.md, no docs/ dir; confirmed via directory listing)

**Specs:**
- `specs/centralized_unifi.md` — the only spec covering this cluster (full design/plan doc: fidelity model, package-vs-build rationale, phased implementation, testing strategy, acceptance criteria)

**web_urls / core dashboards (from outputs.tf):**
`core` is explicitly empty (`core = []`) — this is a log-pipeline-only cluster with no human-facing
dashboard. `all` folds in the enabled `/metrics` exporter endpoints:
- `http://<controller_ipv4>:9100/metrics` (node_exporter, controller — gated on `enable_node_exporter`, default true)
- `http://<controller_ipv4>:9577/metrics` (syslog_ng_exporter, controller only — gated on `enable_syslogng_exporter`, default true)
- `http://<usg_ipv4>:9100/metrics` (node_exporter, usg — gated on `enable_node_exporter`, default true)

**Notes for the doc authors:**
- This cluster is currently **INVISIBLE in CLAUDE.md** — a repo-wide grep for "unifi" in `/Users/bossjones/dev/bossjones/multipass-lab/CLAUDE.md` returns zero matches. It is not named in the `## Clusters` topic sentence, nor mentioned in any later paragraph (unlike `centralized_logging`, `centralized_monitoring`, `centralized_netbox`, `centralized_dns`, which each get prose). The CLAUDE.md author will need to write its clause from scratch, taking style cues from the sibling clusters' one-sentence descriptions in the `## Clusters` section rather than editing existing prose.
- `version_mode` is a notable toggle unique to this cluster: `"exact"` (default) runs period-exact Debian packages in containers (the fidelity-focused design); `"modern"` runs Ubuntu-stock syslog-ng 4.x / rsyslog 8.x on the bare VM for prototyping the native exporter path. Doc authors should mention this if documenting configuration knobs.
- The cluster follows the standard runtime-IP-injection pattern (USG's Vyatta forward target is rendered from the controller's `ipv4` at apply time) and the standard "editing cloud-init needs `just recreate`, not `just up`" gotcha — both already documented in the cluster's own README.md, so no new prose is strictly required there, just cross-referencing if a top-level doc summarizes gotchas fleet-wide.
- First `just up` is notably slow (wheezy container builds under qemu emulation, installs from `archive.debian.org`) — worth a callout if writing a quickstart/tutorial that sets expectations on timing.
- `dns_records` output registers `unifi.<domain>` → the controller's IP in the fleet DNS hub, for uniformity with other clusters, even though there's no real controller UI behind it (it's a logging stand-in).
