# Fact sheet: centralized_dns

**One-liner:** A single VM running AdGuard Home over a recursive Unbound resolver, the
network-wide ad-blocking DNS resolver AND a cross-cluster hub that comes up FIRST in
`just up-connected`.

**VMs:**
| VM role | Count | Sizing | Purpose |
|---|---|---|---|
| `server` (`centralized-dns-server`) | 1 | 2 vCPU / 2G mem / 20G disk (default `var.server`) | Runs AdGuard Home (`0.0.0.0:53`, UI/API `:3000`), Unbound (`127.0.0.1:5335`), and the exporters — all host-level under systemd (no Docker) |

**Existing docs (confirmed to exist on disk):**
- `clusters/centralized_dns/README.md`
- `clusters/centralized_dns/USAGE.md`
- `clusters/centralized_dns/DEFAULT_PASSWORDS.md`

**Specs:**
- `specs/centralized_dns.md` — main design spec (status header says "planned", but the cluster
  is fully implemented and live in the repo — variables.tf/outputs.tf/README all exist and match
  the spec; treat the spec as historical design doc, not current status)
- `specs/cross-cluster.md` — cross-cluster hub-ordering design; `centralized_dns` is documented
  there (§"DNS: the hub that must come up FIRST") as a fourth cross-cluster signal alongside
  logs/metrics, with its own `dns_server` variable and apply-order justification
- `specs/pki-and-dns.md` — combined internal-CA trust + Phase-2 TLS + DNS auto-registration design;
  covers the `adguard_cli.py rewrite-sync` mechanism and `just set-dns`/`set-dns-all`/`verify-dns`
  recipes that register fleet hostnames into this cluster's AdGuard
- `specs/dns-dashboards.md` — Grafana/OpenObserve dashboards for the AdGuard + Unbound exporters.
  **Status: planned, NOT yet built** — its header says "Status: planned", and no `DNS/` dashboard
  folder exists yet under `clusters/centralized_monitoring/cloud-init/grafana/dashboards/` or
  `clusters/centralized_monitoring/openobserve/dashboards/`. The exporters are already scraped by
  Prometheus (via `just up-connected` hot-push) but there is currently no dashboard rendering that
  data — doc authors should flag this as a known gap, not describe dashboards as existing.

**web_urls / core dashboards (from outputs.tf):**
- `core`: AdGuard Home web UI — `http://<server_ip>:3000` (admin creds: `admin` / `test1234` dev
  default, see DEFAULT_PASSWORDS.md)
- `all` (core + enabled exporters, each gated on its `enable_*` flag, all default **on**):
  - `node_exporter` — `http://<server_ip>:9100/metrics`
  - `adguard-exporter` — `http://<server_ip>:9618/metrics`
  - `unbound_exporter` — `http://<server_ip>:9167/metrics`
  - `process-exporter` — `http://<server_ip>:9256/metrics`
  - `systemd_exporter` — `http://<server_ip>:9558/metrics`
- `just open centralized_dns` opens `core`; `--full`/`--all` opens `all`.

**Notes for the doc authors:**
- This cluster is **already correctly covered in CLAUDE.md's** "## Clusters" enumeration sentence
  (line ~23-25: names it, describes AdGuard/Unbound, links `specs/centralized_dns.md`, and states
  it's the cross-cluster hub that comes up FIRST in `just up-connected`) **and** in the Traefik
  fleet-edge paragraph (line ~93, listed among clusters fronted by `centralized_pki`'s Traefik).
  **No CLAUDE.md change is needed for dns** — only top-level `README.md` and `docs/README.md` (or
  equivalent repo-level docs) need new entries pointing at this cluster.
- Two DNS-specific CLIs exist and are auto-discovered by `just verify-api`:
  `clusters/centralized_dns/scripts/adguard_cli.py` and `unbound_cli.py` (uv single-file, typer +
  rich), each exposing a `check` subcommand plus richer introspection (`adguard-status`,
  `unbound-stats`, rewrite management via `adguard_cli.py rewrite-*`).
- Port 53 contention is the trickiest boot-ordering detail: cloud-init must free `:53` from
  `systemd-resolved`'s stub listener (`DNSStubListener=no`) only *after* apt-time name resolution
  is done, then start AdGuard Home, then repoint the VM's own resolver at itself
  (`127.0.0.1`) — documented in `specs/centralized_dns.md` §"Port 53 contention (critical)".
- **Do not `just recreate centralized_dns` while the fleet is up-connected** — it would churn the
  DNS IP and break every other VM's resolver (per USAGE.md). Cloud-init iteration should be done
  via SSH + manual service restart instead, with the fix folded back into the `.tftpl` afterward.
- `domain` variable (default `lab.theblacktonystark.com`) is the DNS suffix used by
  `dns_records`/`reverse_proxy_routes` outputs and the fleet-wide `just set-dns`/`set-dns-all`
  hostname registration flow described in `specs/pki-and-dns.md`.
