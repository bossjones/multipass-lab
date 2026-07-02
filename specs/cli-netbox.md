# Spec: NetBox verification CLI (`netbox-cli`)

## Context

`clusters/centralized_netbox` deploys **NetBox** (via `netbox-community/netbox-docker`) on the
server VM at `http://<server>:8000`, authenticated with a pinned API token
(`var.netbox_api_token`). The headline behaviour of the cluster is **self-registration**: a test
VM POSTs itself into NetBox as a Virtual Machine on first boot.

The live testinfra suite proves this over SSH, but — mirroring the observability CLIs
(`grafana_cli.py`, `prometheus_cli.py`, `openobserve_cli.py`) — we also want a **host-side,
human-drivable** way to ask "is NetBox healthy? does the token authenticate? did the client
register itself with a primary IP?" without writing a new test. This spec designs
`netbox_cli.py`, conforming to the repo conventions in `CLAUDE.md`: uv single-file scripts, the
two-layer (hermetic + testinfra) test split, and Justfile recipes parametrized by **cluster
folder name**.

### Library choice

NetBox ships an official read/write Python SDK,
[`pynetbox`](https://github.com/netbox-community/pynetbox), which wraps the REST API with typed
record objects (`nb.virtualization.virtual_machines.filter(...)`, `.status`, `.primary_ip`). We
use it for object queries — the analog of `grafana-client` / `prometheus-api-client`. The one
endpoint pynetbox does not model cleanly is the unauthenticated health probe `GET /api/status/`,
so `check` hits that with raw `httpx` first (the same raw-HTTP-plus-SDK split `grafana_cli.py`
uses for `/api/health`). The ingestion/IaC SDKs (`pynetbox` write-heavy flows, `netbox-docker`
tooling) are not needed here.

## Objective

Ship `netbox_cli.py` with introspection subcommands and a CI-friendly `check`, wired via
`just netbox-*` recipes, covered by a hermetic pytest suite (real in-process HTTP server, no VM)
plus live use through `just verify-api` / `just netbox-check`.

## Architecture

```
  operator laptop                              centralized-netbox-server VM
  ┌───────────────────────┐   HTTP :8000      ┌──────────────────────────────┐
  │ netbox_cli.py (uv)    │ ────────────────► │ netbox container             │
  │  pynetbox + httpx      │  Token <pinned>   │  /api/status/                │
  │  _obs_common.resolve   │                   │  /api/virtualization/*       │
  │   (tofu output → url)  │ ◄──────────────── │  /api/ipam/*                 │
  └───────────────────────┘                   └──────────────────────────────┘
```

The CLI resolves the base URL and token from `tofu -chdir output -json` (`netbox_url`,
`netbox_api_token`, `registered_vm_name`), or takes explicit `--server-url` / `--token`. The
shared `_obs_common.py` provides target resolution, the `CheckReport` accumulator, and `--json`
output.

## Command surface

Global options (on the app callback): `--cluster` (default `centralized_netbox`), `--server-url`
/ `$NETBOX_URL`, `--token` / `$NETBOX_TOKEN`, `--json`, `--timeout`, `--insecure`.

| Subcommand | NetBox endpoint | Purpose |
|---|---|---|
| `status` | `GET /api/status/` (raw httpx) | NetBox + Django/RQ versions, health |
| `clusters` | `GET /api/virtualization/clusters/` (pynetbox) | list virtualization clusters |
| `vms` | `GET /api/virtualization/virtual-machines/` (pynetbox) | list VMs: name/status/cluster/primary_ip |
| `check` | status + auth + cluster + site + VM + primary-IP | assert & exit nonzero |

Introspection prints a rich table, or clean `json.dumps` under `--json`.

## `check` semantics (exit 0 pass / 2 fail)

Assertions, each a `CheckReport` row (`pass`/`fail`/`skip`):

1. **NetBox reachable** — `GET /api/status/` returns 200 (raw httpx). On connection refused this
   is the single `fail` row and the check short-circuits to exit 2.
2. **Token authenticates** — an authenticated read (e.g. `GET /api/virtualization/clusters/`) does
   not return 401/403.
3. **Cluster present** — the `--cluster-name` (default `centralized-netbox`, resolved from
   `tofu output` when available) exists.
4. **Site present** — the default DCIM `--site-name` (default `multipass-lab`, resolved from
   `tofu output netbox_site_name` when available) exists (NetBox needs a site before any device).
5. **Client VM registered** — the expected VM (`--vm-name`, default the `registered_vm_name`
   `tofu output`) exists with `status=active`.
6. **Primary IP assigned** — that VM has a non-null `primary_ip4`.

Any `fail` → exit 2 (`CHECK_FAIL_EXIT`). In `--server-url` mode (no tofu), the cluster/VM names
that would come from `tofu output` fall back to the documented defaults, and steps that cannot be
resolved are `skip`ped rather than failed.

## Testing

- **Hermetic (primary, TDD):** `clusters/centralized_netbox/tests/netbox/` — a mini uv project
  (`pyproject.toml` with `pythonpath = ["../../scripts"]`, deps `pytest, pytest-httpserver,
  pytest-mock, typer, rich, pynetbox`). Tests stand up `pytest-httpserver` serving canned
  `/api/status/`, `/api/virtualization/clusters/`, `/api/virtualization/virtual-machines/`,
  drive the CLI via `typer.testing.CliRunner` with `--server-url http://<httpserver> --token …`,
  and assert on `--json` output and `check` exit codes. Failure paths covered: NetBox unreachable
  → exit 2, 401 token → exit 2, cluster absent → exit 2, VM missing → exit 2, VM without
  primary IP → exit 2.
- **Live (secondary):** `just netbox-check centralized_netbox` (and `just verify-api
  centralized_netbox`) against a running cluster must exit 0; `tests/testinfra/test_registration.py`
  asserts the same object graph independently.

## Justfile

```
just netbox-check CLUSTER               # check → exit code
just netbox-status CLUSTER              # /api/status/ (versions/health)
just netbox-vms CLUSTER                 # list registered virtual machines
just netbox-clusters CLUSTER            # list virtualization clusters
```

Mirror the `grafana-*` recipe shape: `uv run clusters/<CLUSTER>/scripts/netbox_cli.py --cluster
<CLUSTER> <cmd>`. `verify-api` is generalized to iterate the cluster's `scripts/*_cli.py`
(skipping `heimdall_cli`, which has no `check`), so `just verify-api centralized_netbox` runs
`netbox_cli.py check`.

See also [`specs/centralized_netbox.md`](centralized_netbox.md).
