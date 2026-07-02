# Spec: Centralized NetBox Cluster

## Context

`multipass-lab` prototypes homelab infrastructure with OpenTofu + Multipass before promoting it
to Proxmox. This is the **third cluster** (after `centralized_logging` and
`centralized_monitoring`) and stands up **NetBox** — the open-source DCIM/IPAM "source of truth"
for network and infrastructure inventory. The headline behaviour is **self-registration**: a
throwaway test VM boots and, from its own cloud-init, POSTs itself into NetBox over the REST API.

NetBox is a natural future hub. Once every cluster runs in parallel, each cluster's VMs can
register into this one NetBox as the shared source of truth (kept in mind, **not** built here —
see Future work). The shipper/registration pattern is therefore designed to be reusable: a small,
transparent REST script gated on a runtime-injected server IP, exactly mirroring how
`centralized_logging` injects the central syslog-ng IP into its clients.

Each cluster is **vendored to its own folder** (`clusters/centralized_netbox/`). One `tofu apply`
brings up two Multipass VMs; the root `Justfile` orchestrates by cluster name.

## Objective

`just up centralized_netbox` provisions 2 Multipass VMs via OpenTofu:

1. **server** — runs NetBox via the official
   [`netbox-community/netbox-docker`](https://github.com/netbox-community/netbox-docker)
   docker-compose stack (NetBox + Postgres + Redis + worker + housekeeping), reachable at
   `http://<server>:8000`. Its cloud-init also **bootstraps** a virtualization *cluster-type*
   `Multipass` and *cluster* `centralized-netbox` (so VMs have a home) plus a default DCIM
   *site* `multipass-lab` (NetBox requires a site before any device) via the REST API.
2. **client** — a minimal test VM that, on first boot, runs `netbox-register.sh` (a
   `netbox-register.service` oneshot) which waits for NetBox, then registers **itself** as a
   NetBox **Virtual Machine** (name + `eth0` interface + primary IPv4) into the `centralized-netbox`
   cluster.

Auth uses a **pinned lab API token** (`var.netbox_api_token`) so both the client's self-registration
and the host-side verification are deterministic and need no discovery step. The server bootstrap
**creates that token via `manage.py`** on first boot (see the version note below) — it does not rely
on the image's env-var behaviour.

**NetBox version pin.** We pin netbox-docker to a **NetBox 4.1** release (`var.netbox_docker_ref`,
default `3.0.2`). NetBox 4.2+ replaced plaintext API tokens with a hashed **v2 (Bearer) scheme**
where a *known* token value can no longer be set (the token is generated server-side and shown
once), which defeats a deterministic lab. NetBox 4.1 uses **v1 plaintext tokens**
(`Authorization: Token <40hex>`), so the pinned token works uniformly across the client
self-registration, the host `netbox_cli`, and the testinfra suite.

## Architecture

```
        ┌────────────────────────────┐
        │ centralized-netbox-client  │  netbox-register.service (oneshot)
        │  curl + jq  (cloud-init)    │ ─┐  POST /api/virtualization/virtual-machines/
        └────────────────────────────┘  │  POST /api/virtualization/interfaces/
                                         │  POST /api/ipam/ip-addresses/  → PATCH primary_ip4
                        Authorization:   │  Token <pinned>  (HTTP :8000)
                                         ▼
        ┌───────────────────────────────────────────────────────────────┐
        │ centralized-netbox-server                                     │
        │  netbox-docker: netbox + worker + housekeeping + postgres + redis │
        │  /api/status/   /api/virtualization/*   /api/ipam/*           │
        │  bootstrap: cluster-type "Multipass" + cluster "centralized-netbox" │
        └───────────────────────────────────────────────────────────────┘
          (future: every cluster registers its VMs into this NetBox)
```

### Resource sizing

| VM | vCPU | RAM | Disk | Why |
|----|------|-----|------|-----|
| server | 2 | **4G** | 20G | netbox-docker runs ~6 containers (netbox, worker, housekeeping, postgres, redis, redis-cache) |
| client | 1 | 1G | 10G | tiny — just curl/jq to self-register |
| **total** | **3** | **5G** | **30G** | the heaviest single cluster so far (the server alone wants 4G) |

### Provider & IP injection (the key mechanism)

- Provider: [`larstobi/multipass`](https://registry.terraform.io/providers/larstobi/multipass)
  (`~> 1.4`, public registry). `multipass_instance` exposes `name`, `image`, `cpus`, `memory`,
  `disk`, `cloudinit_file` (a **file path**), and a computed `ipv4`.
- Multipass hands out DHCP IPs, so the NetBox server IP can't be hardcoded. OpenTofu:
  1. creates `server` first,
  2. reads its computed `ipv4`,
  3. renders the client's cloud-init from a `templatefile()` (baking in `netbox_ip`) into a
     `local_file`,
  4. points `multipass_instance.client.cloudinit_file` at that rendered file.

  The implicit dependency edge (client → `local_file` → `server.ipv4` → server instance) orders
  this correctly inside a single `tofu apply`, exactly like the syslog-ng `client_conf` edge in
  `centralized_logging`.

### NetBox deployment (server)

- cloud-init installs Docker + the compose plugin and starts the `netbox-stack` systemd oneshot
  **asynchronously** (`systemctl start --no-block`). This is required: the `larstobi/multipass`
  provider exposes no launch timeout, so `multipass launch` waits on the default **300s** cloud-init
  window — pulling ~6 NetBox images + running migrations inline blows past it and the launch times
  out. cloud-init therefore finishes in ~2 min; NetBox comes up in the background.
- `netbox-stack.sh` (idempotent, wrapped in a retry loop so a transient registry pull just tries
  again) clones `netbox-docker` at `var.netbox_docker_ref`, drops a minimal
  `docker-compose.override.yml` (publish `:8000`→container `:8080`, `SKIP_SUPERUSER=true`,
  `ALLOWED_HOSTS=*`), and `docker compose up -d`.
- Once NetBox responds, it creates the admin superuser + the pinned **v1** API token via
  `manage.py` (deterministic, independent of the image's env-var handling), then **idempotently**
  creates the virtualization cluster-type `var.cluster_type` (`Multipass`), cluster
  `var.cluster_name` (`centralized-netbox`), and a default DCIM site `var.site_name`
  (`multipass-lab`, required before any device can be added) via REST (GET-by-name, POST if
  absent), and writes `/var/lib/netbox-bootstrap/done`.

### Self-registration (client)

`netbox-register.sh` (run by `netbox-register.service`, idempotent + retry-wrapped so re-runs
PATCH rather than duplicate and a transient error or a not-yet-ready server just tries again):

1. wait for **authenticated** `http://<netbox_ip>:8000/api/status/` to return 200 — the server
   provisions the pinned token during its own bootstrap, so this also waits out the server bring-up,
2. resolve this VM's hostname and primary IPv4 (`hostname` + `ip -4 route get`),
3. resolve the cluster id (`GET /api/virtualization/clusters/?name=centralized-netbox`),
4. upsert a **virtual-machine** (`name`, `cluster`, `status=active`) → capture id,
5. upsert a **VMInterface** `eth0` on that VM,
6. upsert an **IPAddress** `<ip>/24` bound to `eth0`, then PATCH the VM's `primary_ip4`,
7. write `/var/lib/netbox-register/done` on success (asserted by testinfra).

All requests carry `Authorization: Token <pinned>`. Token/curl writes are unaffected by NetBox's
CSRF protection (that only applies to browser/session POSTs).

## Layout

```
multipass-lab/
├── Justfile                                   # root orchestrator (cluster arg)
├── specs/centralized_netbox.md                # this document
├── specs/cli-netbox.md                        # the netbox_cli design
└── clusters/centralized_netbox/
    ├── versions.tf  providers.tf  variables.tf  terraform.tfvars
    ├── main.tf      outputs.tf
    ├── cloud-init/
    │   ├── server.yaml.tftpl   client.yaml.tftpl
    │   └── netbox/docker-compose.override.yml.tftpl
    ├── scripts/
    │   ├── netbox_cli.py        # uv single-file verify CLI (typer + rich + pynetbox)
    │   └── _obs_common.py       # shared resolve/CheckReport helpers (cluster-local copy)
    ├── tests/tofu/sizing_and_render.tftest.hcl       # Layer 0/1 hermetic (mock_provider)
    ├── tests/netbox/                                 # Layer 1 hermetic CLI (pytest-httpserver)
    │   ├── pyproject.toml  test_netbox_cli.py
    └── tests/testinfra/                              # Layer 2 live verify (pytest+testinfra/SSH)
        ├── pyproject.toml  conftest.py
        └── test_server.py  test_client.py  test_registration.py  test_ntp.py
```

## Testing — layered feedback loop

Mirrors the repo's two-layer split (see `CLAUDE.md`): a hermetic inner loop, then a live "real
machine" rung verified with **pytest + testinfra** and the **`netbox_cli.py check`**.

- **Layer 0/1 — hermetic (`just check`, no VMs)**: `tofu fmt -check`, `tofu validate`, and
  `tofu test -test-directory=tests/tofu` using `mock_provider "multipass"` (plan-only). Asserts
  sizing/image/names and that the rendered cloud-init carries the netbox-docker bring-up
  (`:8000` override + `docker compose`), the token + cluster bootstrap (the pinned token via
  `manage.py`, cluster-type/cluster via REST), the self-registration REST calls, and the UTC/NTP block.
- **Layer 1 — hermetic CLI (`uv run pytest` in `tests/netbox`)**: drives `netbox_cli.py` against
  a `pytest-httpserver` fake NetBox API via `typer.testing.CliRunner` + `--server-url`/`--token`
  (never touches `tofu`). Covers `check` pass and every failure path (unreachable, 401, cluster
  missing, VM missing, VM without primary IP).
- **Layer 2 — live verify (`just verify` + `just netbox-check`, after `just up`)**: `uv run
  pytest` in `tests/testinfra` connects over SSH:
  - server: docker active, netbox/worker/postgres/redis running, `:8000` listening,
    `/api/status/` 200, cluster-type + cluster present.
  - client: `/var/lib/netbox-register/done` present, `netbox-register.service` succeeded.
  - **E2E (headline)**: query the NetBox API (token + url from `tofu output`) and assert the
    client VM object exists with `status=active`, an `eth0` interface, and `primary_ip4` equal to
    the client's DHCP IP. `just netbox-check` independently asserts the same via the CLI.

## Quickstart

```sh
just check centralized_netbox      # hermetic (fmt + validate + tofu test), no VMs
just up centralized_netbox         # one apply -> 2 VMs (first boot pulls netbox-docker images)
just verify centralized_netbox     # live testinfra: NetBox health + self-registration proof
just netbox-check centralized_netbox   # live API check (exit 0 = pass)
just open centralized_netbox       # open the NetBox UI in the browser
just destroy centralized_netbox    # tofu destroy + prune orphans
```

Requires OpenTofu ≥ 1.7, `multipass`, `uv`, `just`, and an SSH keypair at `~/.ssh/id_ed25519[.pub]`.

## Applying cloud-init / config changes

Editing a cloud-init template updates `.rendered/*.yaml` but does **not** recreate a
`multipass_instance` on plain `just up` (the provider keys on the `cloudinit_file` path, not its
content), and recreating the server alone changes its DHCP IP and breaks the client's baked
`netbox_ip`. Apply config changes with **`just recreate centralized_netbox`** (destroy → up).
Note the Multipass timezone gotcha (`specs/ntp.md`): Multipass injects the host timezone at first
boot, so the cloud-init `runcmd` re-enforces `timedatectl set-timezone Etc/UTC`.

## Future work (kept in mind, not built here)

- **Cross-cluster registration**: point `centralized_logging` / `centralized_monitoring` VMs at
  this NetBox so every cluster registers into the shared source of truth. NetBox binds `0.0.0.0`
  and VMs share the Multipass subnet, so this already works over IP — it needs a small register
  hook in the other clusters' cloud-init plus a per-cluster NetBox cluster object.
- **NetBox plugins**: install a plugin (e.g. `netbox-topology-views`) via a custom netbox-docker
  image (`Dockerfile-Plugins` + `PLUGINS`/`PLUGINS_CONFIG` in configuration) — deferred because it
  requires building an image rather than pulling the published one
  (see <https://netboxlabs.com/docs/netbox/plugins/installation/>).
- **Model VMs as DCIM Devices** (device-type/role/site/manufacturer) instead of virtual-machines,
  for hardware-faithful modelling when promoting to Proxmox.
- **Secrets**: the pinned token is **lab-only** and deliberately exposed via `tofu output`. On
  Proxmox, generate the token and inject it via a secret store — do not copy this pattern.
