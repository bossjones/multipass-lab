# Fact sheet: centralized_netbox

**One-liner:** A NetBox DCIM/IPAM server + a client VM that self-registers via the REST API on
first boot, with an opt-in Diode/orb-agent discovery agent that scans the subnet.

**VMs:**
| VM role | Count | Sizing | Purpose |
|---|---|---|---|
| server | 1 | 2 cpu / 4G / 20G | Runs the netbox-docker stack (NetBox + worker + housekeeping + postgres + redis); bootstraps cluster-type/cluster/site, seeds a base data model, and (opt-in) builds the diode-netbox-plugin image + hosts the Diode ingestion stack. |
| client | 1 | 1 cpu / 1G / 10G | Minimal test VM; on first boot POSTs itself into NetBox as a Virtual Machine (self-registration). |
| agent | 0 or 1 (count-gated on `enable_discovery`, default off) | 1 cpu / 1G / 10G | Runs `netboxlabs/orb-agent` to scan the Multipass `/24` (network_discovery/nmap) and ingest results into NetBox via Diode over gRPC. |

**Existing docs (confirmed to exist on disk):**
This cluster has NO `README.md`, NO `USAGE.md`, NO `docs/` directory — only `scripts/` (the
`netbox_cli.py` verification CLI + `_obs_common.py`) and `tests/` (`tests/tofu/`, `tests/netbox/`,
`tests/testinfra/`). Confirmed via `ls clusters/centralized_netbox/`, which lists only:
`.rendered/`, `.terraform/`, `cloud-init/`, `scripts/`, `tests/`, plus the standard `.tf` files
(`main.tf`, `outputs.tf`, `variables.tf`, `providers.tf`, `versions.tf`, `terraform.tfvars`) and
generated/gitignored state.

**Specs:**
- `specs/centralized_netbox.md` — main design spec (architecture, resource sizing, self-registration
  flow, base data model seed, testing layers, quickstart)
- `specs/cli-netbox.md` — the `netbox_cli.py` verification CLI design (command surface, `check`
  semantics, hermetic + live testing)
- `specs/netbox-data.md` — base data-model seed design (org hierarchy, DCIM device library, host
  Device, IPAM, tenancy — implemented; historical planning doc)
- `specs/netbox-discovery.md` — opt-in Diode/orb-agent discovery design (NetBox version-pin
  tradeoffs, Diode server stack, orb-agent VM, deterministic OAuth2 secrets)

**web_urls / core dashboards (from outputs.tf):**
- `core`: NetBox UI at `http://<server_ipv4>:8000/` (var `netbox_port`, default `8000`).
- `all` adds: the REST API root (`http://<server_ipv4>:8000/api/`); enabled Prometheus exporters
  on both server and client — node_exporter `:9100/metrics`, process-exporter `:9256/metrics`,
  systemd_exporter `:9558/metrics` (all three default **on**); the Diode ingress
  `http://<server_ipv4>:8080` (var `diode_port`) **only when `enable_discovery` is true**; and
  Netdata dashboards on both server and client at `:19999` (default **on**, `enable_netdata`).
- Other notable outputs: `netbox_url`, `netbox_api_token` (pinned lab-only token), `hosts` (role →
  {name, ipv4}, includes `agent` only when discovery is on), `dns_records` (`netbox.<domain>` and,
  when discovery is on, `diode.<domain>`), `reverse_proxy_routes` (fleet-edge Traefik candidate,
  `netbox` host), `discovery_enabled`, `diode_url`, `diode_ingest_client_id`, `enabled_features`,
  `enabled_exporters`, `docker_tools_enabled`, `netbox_prefix` (derived `/24`), plus several seed
  echo-outputs (`netbox_region`, `netbox_rack_name`, `netbox_host_device_name`,
  `netbox_cluster_name`, `netbox_site_name`, `registered_vm_name`).

**Notes for the doc authors:**
This cluster is ALREADY correctly covered in CLAUDE.md's "## Clusters" enumeration sentence
("`clusters/centralized_netbox/` (a NetBox DCIM/IPAM server + a test VM that **self-registers**
into it via the REST API on first boot; see `specs/centralized_netbox.md`)") — the CLAUDE.md
author should make NO change for netbox. Only `README.md` and `docs/README.md` (repo-level docs,
not this cluster's own dir, which has none) need new entries pointing at this cluster and its four
specs. Two things worth flagging to whoever writes those entries: (1) the NetBox version is
deliberately pinned to **4.1** (not latest) so the API token stays a settable v1 plaintext value —
this is a load-bearing design constraint, not staleness; (2) `enable_discovery` is off by default
and, when flipped on, requires `just recreate centralized_netbox` (not `just up`), same as every
other cloud-init-gated opt-in flag in this repo.
