# Plan: Seed a NetBox base data model on bootstrap (`centralized_netbox`)

## Task Description

The `centralized_netbox` cluster stands NetBox up and self-registers the client, but the
inventory is almost empty: **Regions, Site Groups, Locations, Rack Types, Racks, Manufacturers,
Device Types, Device Roles, Platforms, Contacts, and all of IPAM** have no data, and
`/dcim/devices/` shows nothing. This plan extends the server bootstrap to seed a realistic,
idempotent **base data model** on first boot — the organizational hierarchy, a DCIM device
library, a rack with a real device (the Multipass host), and IPAM populated with the lab's
*actual* subnet and IPs — so a freshly `just up`-ed NetBox is immediately useful and every
navigation tab the user opened has representative data.

It also resolves the user's specific confusion (see "Why the client isn't under /dcim/devices/").

## Objective

After `just up centralized_netbox` (or `just recreate`), a fresh NetBox contains a coherent,
linked data model seeded entirely by cloud-init:

- **Organization**: Region → Site Group → Site (`multipass-lab`) → Location, plus a Tenant.
- **DCIM library**: Manufacturer(s), Platform(s), Device Role(s), a Rack Role, a Rack Type, and a
  Rack — everything needed to add a device.
- **DCIM device**: one real **Device** representing the physical Multipass host, mounted in the
  rack — so `/dcim/devices/` is no longer empty.
- **Virtualization**: the cluster is scoped to the site; the client (and server) appear as VMs
  linked to the host device.
- **IPAM**: RIR (RFC1918) → Aggregate → **Prefix matching the live Multipass /24** → VLAN, and the
  client's real IP lands *inside* that prefix (utilization is real, not fictional).
- **Tenancy**: a Contact + Contact Role assigned to the site.

All of it is idempotent (GET-by-name → POST/PATCH-if-absent) and TDD-verified across the repo's
three test layers. `just netbox-check` and `just verify centralized_netbox` both pass.

## Problem Statement

Two distinct issues:

1. **"Why don't I see `centralized-netbox-client` under `/dcim/devices/`?"** — Because it isn't a
   DCIM Device. The client cloud-init registers it as a **Virtualization → Virtual Machine** (the
   correct NetBox model for a Multipass guest). It *is* in NetBox, at
   `/virtualization/virtual-machines/`. `/dcim/devices/` is a different object class (physical
   hardware) and nothing in the bootstrap creates one, so that table is empty. This is expected
   behaviour, not a bug — but the UX is confusing and worth fixing by (a) documenting the split and
   (b) seeding a genuine DCIM Device (the host) so the DCIM side has real data.

2. **The rest of NetBox is empty scaffolding.** NetBox is only useful once its foundational data
   model exists (Sites, Manufacturers, Device Types, Device Roles, IPAM prefixes…). Every tab the
   user opened (`/dcim/rack-types/`, `/dcim/regions/`, `/dcim/site-groups/`, `/dcim/locations/`,
   `/tenancy/contacts/`, `/dcim/devices/`) is empty because the bootstrap seeds only a
   cluster-type, a cluster, and one site. There is no built-in "demo data" in netbox-docker, so we
   must seed it ourselves.

## Solution Approach

Extend the **existing server bootstrap** (`cloud-init/server.yaml.tftpl` → `netbox-stack.sh`)
rather than adding new machinery. The current `provision()` already does GET-by-name/POST
idempotent REST calls for cluster-type, cluster, and site; we append a **data-model seed** in the
same function so it inherits the existing retry loop, single `Authorization: Token` auth, and the
one `/var/lib/netbox-bootstrap/done` marker. To keep the (already long) script readable, factor
the seed into a dedicated rendered script `netbox-seed.sh` that `netbox-stack.sh` **calls at the
end of `provision()`** (still one oneshot, one retry, one marker; a nonzero seed exit fails
`provision` and retries).

Key design choices, matching the three answered questions:

- **Model the Multipass host as a DCIM Device** (not the VMs). The host is genuinely physical
  hardware, so a Device named `multipass-host` (device-type + role `hypervisor`, mounted in a
  seeded rack at U1) is modeling-faithful and gives `/dcim/devices/` a real entry. The VMs stay
  under Virtualization, but each VM's `device` field is linked to the host Device so the two models
  connect (VM "runs on" host).
- **Full base model.** Seed the entire organizational + DCIM-library + IPAM + tenancy graph with
  one representative object per empty table.
- **Real IPs.** Derive the subnet from the server's own primary IP at runtime
  (`$${SERVER_IP%.*}.0/24`), seed the Prefix + Aggregate from it, and let the client's existing
  `IPAddress` POST land inside that prefix (NetBox auto-associates by CIDR containment). Also seed
  the `.1` gateway IP. IPAM utilization then reflects the live lab.

The seed is **dynamic where reality demands it** (subnet/aggregate derived from the running IP) and
**variable-driven where a lab operator might customize it** (region/site-group/tenant/rack/host
manufacturer names), with everything else sane-defaulted in the script.

## Relevant Files

Use these files to complete the task:

- `clusters/centralized_netbox/cloud-init/server.yaml.tftpl` — the bootstrap. Add the
  `netbox-seed.sh` `write_files` entry and call it at the end of `provision()`. New template vars
  are threaded from `main.tf`. This is where all seeding lives.
- `clusters/centralized_netbox/main.tf` — add locals (slugs for the new names) and pass the new
  template variables into the `local_file.server_ci` `templatefile()` call. The client template
  gains `host_device_name` so the client can link its VM to the host Device.
- `clusters/centralized_netbox/cloud-init/client.yaml.tftpl` — `netbox-register.sh`: resolve the
  host Device id (`GET /api/dcim/devices/?name=<host>`) and include `device` in the VM upsert so
  the client VM links to the host. (IP already lands in the seeded prefix — no change needed there.)
- `clusters/centralized_netbox/variables.tf` — add the operator-facing seed variables (region,
  site group, location, tenant, rack name, host device name/manufacturer/model) with defaults.
- `clusters/centralized_netbox/outputs.tf` — add `netbox_region`, `netbox_rack_name`,
  `netbox_host_device_name`, and a computed `netbox_prefix` (derive the `/24` from
  `multipass_instance.server.ipv4`) so `netbox_cli` and testinfra can resolve the seeded objects
  the same way they resolve `netbox_site_name`.
- `clusters/centralized_netbox/scripts/netbox_cli.py` — extend `check` to assert the base model is
  present (manufacturer, device-type, device-role, rack, host **device**, prefix); add `devices`
  and `prefixes` introspection subcommands (mirror `vms`/`clusters`).
- `clusters/centralized_netbox/tests/tofu/sizing_and_render.tftest.hcl` — hermetic: `strcontains`
  assertions that the rendered server cloud-init carries every new REST endpoint + seeded
  name/slug + the subnet-derivation snippet.
- `clusters/centralized_netbox/tests/netbox/test_netbox_cli.py` — hermetic CLI: extend the
  `pytest-httpserver` fake to serve the new endpoints; assert the new `check` rows and subcommands.
- `clusters/centralized_netbox/tests/testinfra/conftest.py` — extend the `netbox` fixture to carry
  the new resolved names (`region`, `rack`, `host_device`, `prefix`).
- `specs/centralized_netbox.md`, `specs/cli-netbox.md` — update to document the base data model and
  the VM-vs-Device distinction (remove "Model VMs as DCIM Devices" from Future work — partially done).

### New Files

- `clusters/centralized_netbox/tests/testinfra/test_data_model.py` — live proof: the seeded
  organizational hierarchy, DCIM library, host Device (in `/dcim/devices/`, active, in the rack),
  IPAM prefix containing the client IP, and the VM→host `device` link all exist via the REST API.

## Implementation Phases

### Phase 1: Foundation
Add the seed variables + outputs + `main.tf` template wiring (no behaviour yet — plan-renderable).
Update the two spec docs.

### Phase 2: Core Implementation (TDD, red → green)
Hermetic tofu test asserts the rendered seed strings → implement `netbox-seed.sh` + wiring.
Hermetic CLI test asserts the new `check` rows/subcommands → extend `netbox_cli.py`.

### Phase 3: Integration & Polish
Write live `test_data_model.py`, `just recreate centralized_netbox`, iterate the seed script
against the live 4.1 API until `just verify` + `just netbox-check` are green. Confirm the UI tabs
are populated (`just open centralized_netbox`).

## Step by Step Tasks

IMPORTANT: Execute every step in order, top to bottom. Build **red → green** at each test layer.
Note the two `templatefile` escaping rules used throughout the existing script: bash `$` becomes
`$$` (e.g. `$${auth[@]}`, `$${SERVER_IP%.*}`) and a literal `%{` becomes `%%{` (e.g.
`%%{http_code}`).

### 1. Update the spec docs

- In `specs/centralized_netbox.md`: add a short **"Virtual Machines vs. DCIM Devices"** note (the
  client is a VM under Virtualization by design; the host is the DCIM Device) and a **"Base data
  model"** subsection listing what the bootstrap seeds. Move "Model VMs as DCIM Devices" out of
  Future work (now: host is a Device, VMs link to it).
- In `specs/cli-netbox.md`: add the new `devices`/`prefixes` subcommands and the base-model `check`
  rows to the command surface + `check` semantics tables.

### 2. Add seed variables (`variables.tf`)

Add, each with a slug computed in `main.tf` locals (`lower(replace(x, " ", "-"))`):

```hcl
variable "netbox_region"            { type = string, default = "Homelab" }
variable "netbox_site_group"        { type = string, default = "Multipass" }
variable "netbox_location"          { type = string, default = "Lab Rack Room" }
variable "netbox_tenant"            { type = string, default = "homelab" }
variable "netbox_rack_name"         { type = string, default = "multipass-rack-1" }
variable "netbox_host_device_name"  { type = string, default = "multipass-host" }
variable "netbox_host_manufacturer" { type = string, default = "Apple" }   # machine running Multipass; override for non-Mac hosts
variable "netbox_host_model"        { type = string, default = "Multipass Host" }
```

(Device roles `hypervisor`/`server`, platform `Ubuntu 24.04`, RIR `RFC1918`, VLAN `lab`/vid 100,
and the contact are illustrative and hardcoded in the seed script — they're unlikely to be
customized per lab.)

### 3. Add outputs (`outputs.tf`)

```hcl
output "netbox_region"           { value = var.netbox_region }
output "netbox_rack_name"        { value = var.netbox_rack_name }
output "netbox_host_device_name" { value = var.netbox_host_device_name }
# The Multipass /24 the server sits on, derived from its DHCP IP (e.g. 192.168.252.0/24).
output "netbox_prefix" {
  value = "${join(".", slice(split(".", multipass_instance.server.ipv4), 0, 3))}.0/24"
}
```

### 4. Thread template vars (`main.tf`)

- Add slug locals for each new name (`region_slug`, `site_group_slug`, `location_slug`,
  `tenant_slug`, `rack_slug`, `host_manufacturer_slug`, `host_model_slug`).
- Pass region/site-group/location/tenant/rack/host-* (name + slug) and `server_name` into the
  `templatefile()` for `local_file.server_ci`.
- Pass `host_device_name = var.netbox_host_device_name` into `local_file.client_ci` so the client
  can link its VM to the host Device.

### 5. Hermetic tofu test FIRST (red), then the seed script (green)

- Extend `tests/tofu/sizing_and_render.tftest.hcl` with `strcontains(server_ci, …)` assertions for
  every new endpoint and seeded token:
  `/api/dcim/regions/`, `/api/dcim/site-groups/`, `/api/dcim/locations/`,
  `/api/dcim/manufacturers/`, `/api/dcim/platforms/`, `/api/dcim/device-roles/`,
  `/api/dcim/device-types/`, `/api/dcim/rack-roles/`, `/api/dcim/rack-types/`, `/api/dcim/racks/`,
  `/api/dcim/devices/`, `/api/ipam/rirs/`, `/api/ipam/aggregates/`, `/api/ipam/prefixes/`,
  `/api/ipam/vlans/`, `/api/tenancy/tenants/`, `/api/tenancy/contact-roles/`,
  `/api/tenancy/contacts/`, `/api/tenancy/contact-assignments/`; the seeded names/slugs
  (`Homelab`/`homelab`, `multipass-rack-1`, `multipass-host`, `RFC1918`); and the subnet-derivation
  snippet (`$${SERVER_IP%.*}.0/24`). Also assert the client renders `/api/dcim/devices/?name=` (host
  lookup). Run `just check centralized_netbox` → **red**.
- Implement `netbox-seed.sh` as a `write_files` entry and call it at the end of `provision()` in
  `netbox-stack.sh`, exporting `NETBOX_URL` + `TOKEN`. Seed **in dependency order** (each GET-by-name
  → POST/PATCH-if-absent, capturing ids):

  1. **Region** → **Site Group** → **PATCH Site** (`multipass-lab`) to attach `region` + `group`
     → **Location** (in site).
  2. **Tenant** → PATCH Site `tenant`.
  3. **Manufacturer** (`var.netbox_host_manufacturer`) and **Canonical** (for the OS/VMs).
  4. **Platform** `Ubuntu 24.04` (manufacturer Canonical).
  5. **Device Role** `hypervisor` (color, `vm_role=false`) and `server` (`vm_role=true`).
  6. **Rack Role** → **Rack Type** (manufacturer, model, `u_height`, `width=19`,
     `form_factor=4-post-frame`) → **Rack** (`var.netbox_rack_name`, site, location, `status=active`,
     `rack_type`).
  7. **Device** `var.netbox_host_device_name` — `device_type` (host manufacturer + model, create if
     absent), `role=hypervisor`, `site`, `location`, `rack`, `position=1`, `face=front`,
     `status=active`. (This is the entry that populates `/dcim/devices/`.)
  8. **PATCH Cluster** (`centralized-netbox`) to attach `site` (NetBox 4.1 uses the `site` field).
  9. **Register the server itself as a VM** (name `server_name`, cluster, `status=active`,
     `device=<host id>`, `platform=Ubuntu 24.04`) + `eth0` VMInterface + IPAddress (server IP `/24`)
     + PATCH `primary_ip4`. (Symmetry with the client; the server knows its own IP at runtime.)
  10. **IPAM**: derive `SERVER_IP` (`ip -4 route get 1.1.1.1 … src`), `SUBNET=$${SERVER_IP%.*}.0/24`,
      `AGG="$(echo $SERVER_IP | cut -d. -f1-2).0.0/16"`, `GW=$${SERVER_IP%.*}.1`. Create **RIR**
      `RFC1918` (`is_private=true`) → **Aggregate** `$AGG` (rir) → **VLAN** vid 100 `lab` (site) →
      **Prefix** `$SUBNET` (site, vlan, `status=active`) → **IPAddress** `$GW/24`
      (`dns_name=gateway`). The client's own IP POST lands in `$SUBNET` automatically.
  11. **Tenancy contact**: **Contact Group** → **Contact Role** `Administrator` → **Contact**
      `Lab Admin` → **Contact Assignment** to the site (`object_type=dcim.site`).

  Re-run `just check` → **green**.

### 6. Client links its VM to the host Device (`client.yaml.tftpl`)

- In `netbox-register.sh`, before the VM upsert, resolve
  `host_id="$(curl … /api/dcim/devices/?name=${host_device_name} | jq -r '.results[0].id // empty')"`
  and include `"device": $host_id` in the virtual-machine POST/PATCH body (omit if empty, so the
  register step never hard-fails on a race). Keep it idempotent.

### 7. Hermetic CLI test FIRST (red), then `netbox_cli.py` (green)

- In `tests/netbox/test_netbox_cli.py`, extend the `pytest-httpserver` fake to serve
  `/api/dcim/manufacturers/`, `/api/dcim/device-types/`, `/api/dcim/device-roles/`,
  `/api/dcim/racks/`, `/api/dcim/devices/`, `/api/ipam/prefixes/`. Add tests: `check` now includes
  rows `manufacturer present`, `device-type present`, `device-role present`, `rack present`,
  `host device present`, `prefix present` — all pass on the happy path and each drives exit 2 when
  its object is missing. Add `devices`/`prefixes` subcommand JSON-output tests. Run
  `cd clusters/centralized_netbox/tests/netbox && uv run pytest` → **red**.
- Implement in `netbox_cli.py`: fold the new assertions into `check` (resolve `host_device`/`region`/
  `rack`/`prefix` names via `tofu output` in `resolve()`, defaulting when `--server-url` is used);
  add `devices` (`nb.dcim.devices.all()` → name/role/site/rack/status) and `prefixes`
  (`nb.ipam.prefixes.all()` → prefix/site/vlan/status). → **green**. `ruff check` clean.

### 8. Live testinfra test (`test_data_model.py`)

- New `test_data_model.py` (uses the existing `api`/`netbox`/`hosts` fixtures) asserting, over the
  REST API from the host:
  - Site `multipass-lab` has non-null `region` and `group`.
  - Manufacturer, Platform, Device Role `hypervisor`, Device Type all exist.
  - Rack `multipass-rack-1` exists in the site; **Device `multipass-host` exists in
    `/dcim/devices/`**, `status=active`, mounted in that rack (`rack` + `position` set).
  - RIR `RFC1918`, Aggregate, **Prefix == `tofu output netbox_prefix`** all exist; the client VM's
    `primary_ip4` is *contained* in the prefix (`GET /api/ipam/prefixes/<id>/available-ips/` or
    assert `str(ip) startswith subnet /24`).
  - The client VM's `device` links to `multipass-host`.
  - A Contact assigned to the site exists.
- Extend `conftest.py`'s `netbox` fixture with `region`, `rack`, `host_device`, `prefix` from
  `tofu_output`.

### 9. Bring it up and iterate to green

- `just check centralized_netbox` (hermetic gate) → `just recreate centralized_netbox` (**cloud-init
  changed — recreate, not `up`**). NetBox 4.1 field caveats to verify live (adjust the seed script
  red→green if the API disagrees): Device uses **`role`** (not `device_role`); **Rack Types are new
  in 4.1** (`/api/dcim/rack-types/` exists); Cluster uses **`site`** (scope generalized to
  `scope_type`/`scope_id` only in 4.2); VM accepts a **`device`** field.
- Iterate until `just verify centralized_netbox` and `just netbox-check centralized_netbox` are
  green. Eyeball the UI: `just open centralized_netbox` → confirm Regions, Site Groups, Locations,
  Rack Types, Racks, Manufacturers, Device Types, Device Roles, **Devices**, Contacts, and IPAM
  Prefixes are all populated.

### 10. Final validation

- Run the full Validation Commands block below; confirm all three layers green and the other
  clusters' `verify-api` behaviour is unchanged.

## Testing Strategy

Three layers, matching repo convention:

- **Hermetic tofu (`just check`, no VMs):** `strcontains` assertions that the rendered server
  cloud-init carries every seed REST endpoint, the seeded names/slugs, and the runtime
  subnet-derivation; that the client renders the host-Device lookup. Zero-cost structural proof the
  seed is wired.
- **Hermetic CLI (`uv run pytest` in `tests/netbox`):** `pytest-httpserver` fakes the new endpoints;
  drives `netbox_cli check` + `devices`/`prefixes` via `CliRunner`. Covers the happy path and a
  fail-exit-2 path per new object (missing manufacturer/device-type/role/rack/host-device/prefix).
- **Live testinfra (`just verify` + `just netbox-check`):** `test_data_model.py` proves the real
  object graph exists and is *linked* (site→region, device→rack, VM→device, IP∈prefix) — the true
  end-to-end proof. Idempotency: re-running the seed (via `just recreate`, or by re-invoking the
  oneshot) must not duplicate objects — assert single instances by name.

**Edge cases:** seed runs before NetBox is fully migrated (the existing readiness wait covers it);
transient POST failure (existing retry loop re-runs the idempotent seed); the client wins the race
and its IP POST precedes the prefix seed (harmless — NetBox back-associates by CIDR, and the prefix
GET-by-name/POST is still idempotent); a non-Mac host (override `netbox_host_manufacturer`).

## Acceptance Criteria

- `just check centralized_netbox` passes (hermetic tofu green, incl. the new seed assertions).
- `cd clusters/centralized_netbox/tests/netbox && uv run pytest` passes (new `check` rows +
  `devices`/`prefixes` subcommands).
- After `just recreate centralized_netbox`, `/dcim/devices/` contains **`multipass-host`** (active,
  racked), and Regions, Site Groups, Locations, Rack Types, Racks, Manufacturers, Device Types,
  Device Roles, Platforms, Contacts, and IPAM Prefixes are all non-empty.
- The client VM still self-registers, now with `device = multipass-host`, and its `primary_ip4` is
  contained in `tofu output netbox_prefix`.
- `just verify centralized_netbox` and `just netbox-check centralized_netbox` exit 0.
- `just verify-all` / `verify-api` for the other clusters is unchanged; the seed is idempotent
  (recreate/re-run creates no duplicates).

## Validation Commands

Run from the repo root unless noted:

- `just check centralized_netbox` — hermetic tofu (fmt + validate + test), no VMs.
- `tofu -chdir=clusters/centralized_netbox test -test-directory=tests/tofu` — hermetic tofu alone.
- `cd clusters/centralized_netbox/tests/netbox && uv run pytest -v` — hermetic CLI suite.
- `ruff check clusters/centralized_netbox/scripts` — lint the CLI.
- `just recreate centralized_netbox` — redeploy cloud-init (NOT `just up`) so the new seed runs.
- `just verify centralized_netbox` — live testinfra incl. `test_data_model.py`.
- `just netbox-check centralized_netbox` — live API check (exit 0 = pass).
- `uv run clusters/centralized_netbox/scripts/netbox_cli.py --cluster centralized_netbox devices` — eyeball the host Device.
- `uv run clusters/centralized_netbox/scripts/netbox_cli.py --cluster centralized_netbox prefixes` — eyeball the seeded prefix.
- `just open centralized_netbox` — visually confirm every tab is populated.

## Notes

### Why the client isn't under `/dcim/devices/` (answer to the reported issue)

NetBox separates **physical hardware** (`DCIM → Devices`) from **virtual guests**
(`Virtualization → Virtual Machines`). A Multipass instance is a guest, so the client self-registers
as a **Virtual Machine** — it lives at `/virtualization/virtual-machines/`, not `/dcim/devices/`.
That table is empty only because nothing created a physical Device. This plan seeds one (the
Multipass **host**, which really is hardware) and links the VMs to it via the VM `device` field, so
both models are populated and connected. This is the intended NetBox modeling; we keep VMs as VMs.

### NetBox 4.1 API field caveats (verify live during TDD)

- **Device**: create with **`role`** (the `device_role` field was removed in 4.0).
- **Rack Types**: new object class in **4.1** (`/api/dcim/rack-types/`) — the cluster is pinned to
  4.1, so this endpoint exists; a Rack may reference `rack_type`.
- **Cluster**: 4.1 uses the **`site`** field; the generic `scope_type`/`scope_id` came in 4.2 (which
  we deliberately don't run — see the token-scheme pin in `specs/centralized_netbox.md`).
- **VM**: accepts a **`device`** field (the host it runs on) and `platform` — but NetBox rejects
  the link unless that **Device is assigned to the VM's cluster** (`"The selected device … is not
  assigned to this cluster."`). The seed therefore sets the host Device's `cluster` (in the POST
  body and via a follow-up PATCH for a device created before this rule was handled), and the client
  gates its registration on the host Device existing so the link is deterministic, not racy.
- Tokens remain **v1 plaintext** (`Authorization: Token <40hex>`) — no change; the pinned token
  keeps working for every seed call.

### Bash gotcha: `set -e` under `if provision`

`netbox-stack.sh` runs its steps inside `provision()`, which is invoked as `if provision; then …`
in the retry loop. Bash **ignores `set -e` for the entire dynamic extent of a function called in an
`if`/`&&`/`||` condition — even if the function sets `-e` itself.** So a failing seed would fall
straight through to `touch …/done` and falsely mark success. The seed call therefore uses an
explicit `/usr/local/sbin/netbox-seed.sh || return 1` to propagate failure into the retry loop.

### No new libraries

The seed is pure `curl`/`jq` in cloud-init (already installed) plus the existing `pynetbox`/`httpx`
in `netbox_cli.py`. No `uv add` / no new test deps.

### Helpful URLs (for future NetBox data-model work)

- NetBox configuration reference — <https://netboxlabs.com/docs/netbox/configuration/>
- **NetBox "Zero to Hero" course** (authoritative initial-data-model walkthrough: sites →
  manufacturers → device types → device roles → devices → IPAM) —
  <https://github.com/netbox-community/netbox-zero-to-hero>
- NetBox IPAM feature docs — <https://netboxlabs.com/docs/netbox/features/ipam/>
- In-depth IPAM guide (RIR → aggregate → prefix → IP order) — <https://netboxlabs.com/blog/netbox-ipam/>
- DCIM feature docs (racks, device types, devices) — <https://netboxlabs.com/docs/netbox/features/dcim/>
- REST API reference / browsable API at `/api/` — <https://netboxlabs.com/docs/netbox/integrations/rest-api/>
- **Community device-type library** (pre-built device-type YAML to import real hardware) —
  <https://github.com/netbox-community/devicetype-library>
- `pynetbox` SDK docs (used by `netbox_cli.py`) — <https://pynetbox.readthedocs.io/>
- netbox-docker (the deployment we pin) — <https://github.com/netbox-community/netbox-docker>
- NetBox 4.1 release notes (Rack Types) — <https://netboxlabs.com/docs/netbox/release-notes/version-4.1/>
- IPv4 management walkthrough (sites → RIR → aggregates → prefixes) —
  <https://oneuptime.com/blog/post/2026-03-20-install-netbox-ipv4-address-management/view>
- Referenced video (transcript not machine-fetchable; listed for the operator) —
  <https://www.youtube.com/watch?v=Ic_tuGBF4lQ>
