# Spec: Grafana verification CLI (`grafana-cli`)

## Context

`clusters/centralized_monitoring` deploys **Grafana** (`grafana/grafana:latest`) on the
server VM at `http://<server>:3000` (default creds `admin` / `admin`), provisioned with
two datasources — **Prometheus** (`http://prometheus:9090`) and **OpenObserve**
(`http://openobserve:5080/api/default/prometheus`, basic-auth) — plus a suite of
dashboards under `cloud-init/grafana/dashboards/`.

Today the only programmatic check of Grafana is the live testinfra suite, which shells
`curl http://admin:admin@localhost:3000/api/...` **over SSH on the VM**. There is no
host-side, human-drivable way to ask "is Grafana healthy? are its datasources actually
reachable? did the dashboards provision?" outside of writing a new test.

This spec designs `grafana_cli.py` — a **uv single-file CLI** run from the laptop that
talks to the Grafana HTTP API for both **introspection** (dump/list) and **verification**
(a `check` that asserts and exits nonzero for CI). It conforms to the repo conventions in
`CLAUDE.md`: uv single-file scripts, the two-layer (hermetic + testinfra) test split, and
Justfile recipes parametrized by **cluster folder name**.

### Library choice

The requested `grafana-foundation-sdk` **builds dashboard JSON as code** — it has no HTTP
client and cannot read a running server. For read/verify we use
[`grafana-client`](https://github.com/grafana-toolbox/grafana-client) (`GrafanaApi`), a
maintained wrapper over the Grafana HTTP API. `grafana-foundation-sdk` is reserved for the
opt-in **e2e loop** (build a throwaway dashboard → push → read back → delete).

## Objective

Ship `grafana_cli.py` with introspection subcommands and a CI-friendly `check`, wired via
`just grafana-*` recipes, covered by a hermetic pytest suite (real in-process HTTP server,
no VM) plus an optional live smoke check.

## Architecture

```
  operator laptop                              centralized-monitoring-server VM
  ┌───────────────────────┐   HTTP :3000      ┌──────────────────────────────┐
  │ grafana_cli.py (uv)   │ ────────────────► │ grafana container            │
  │  grafana-client        │   basic auth      │  /api/health                 │
  │  _obs_common.resolve   │                   │  /api/datasources[/uid/*/health]
  │   (tofu output → ip)   │ ◄──────────────── │  /api/search, /api/dashboards│
  └───────────────────────┘                   └──────────────────────────────┘
```

The CLI resolves the server IP from `tofu -chdir output -json` (`server_ipv4`), or takes
an explicit `--server-url`. All Grafana logic goes through `grafana-client`; the shared
`_obs_common.py` provides target/credential resolution, the `CheckReport` accumulator, and
`--json` output.

## Command surface

Global options (from `_obs_common`, on the app callback): `--cluster`
(default `centralized_monitoring`), `--server-url` / `$GRAFANA_URL`, `--user` /
`$GRAFANA_USER` (default `admin`), `--password` / `$GRAFANA_PASSWORD` (default `admin`),
`--json`, `--timeout`, `--insecure`.

| Subcommand | Grafana endpoint (via grafana-client) | Purpose |
|---|---|---|
| `health` | `GET /api/health` (`health.check()`) | version/db status |
| `datasources` | `GET /api/datasources` (`datasource.list_datasources()`) | list name/type/uid |
| `datasource-health NAME` | resolve name→uid, `GET /api/datasources/uid/{uid}/health` (`datasource.health(uid)`) | live datasource probe |
| `dashboards` | `GET /api/search?type=dash-db` (`search.search_dashboards(type_="dash-db")`) | list uid/title/folder |
| `dashboard UID` | `GET /api/dashboards/uid/{uid}` (`dashboard.get_dashboard(uid)`) | dump one dashboard |
| `alert-rules` | `GET /api/v1/provisioning/alert-rules` (stdlib GET; tolerant of 404→`[]`) | list Grafana-managed alert rules (empty in this lab) |
| `check` | health + datasources + datasource-health + search | assert & exit nonzero |

Introspection prints a rich table, or clean `json.dumps` under `--json`.

## `check` semantics (exit 0 pass / 2 fail)

Assertions, each a `CheckReport` row (`pass`/`fail`/`skip`):
1. **Grafana health** — `health.check()["database"] == "ok"`.
2. **Prometheus datasource** — present in `list_datasources()` **and** `datasource.health(uid)`
   status is `OK`.
3. **OpenObserve datasource** — if present, its health must be `OK`; if absent, `skip`
   (it is flag-gated by `enable_openobserve`).
4. **Dashboards provisioned** — `search_dashboards(type_="dash-db")` returns ≥ 1
   (override the minimum with `--min-dashboards N`).

Any `fail` → exit 2. Connection refused / 401 → a single `fail` row + exit 2.

## e2e loop (opt-in, `check --e2e` or `just grafana-e2e`)

Build a uniquely-named dashboard with `grafana-foundation-sdk`, create it via
`dashboard.update_dashboard()`, read it back via `get_dashboard(uid)`, assert the title
round-trips, then delete it. Validates the write path and JSON compatibility. Off by
default (mutates Grafana).

## Testing

- **Hermetic (primary, TDD):** `clusters/centralized_monitoring/tests/grafana/` — a mini
  uv project (`pyproject.toml` with `pythonpath = ["../../scripts"]`, deps
  `pytest, pytest-httpserver, pytest-mock, pytest-cov, pytest-randomly, typer, rich,
  grafana-client`). Tests stand up `pytest-httpserver` serving canned `/api/health`,
  `/api/datasources`, `/api/datasources/uid/*/health`, `/api/search`,
  `/api/dashboards/uid/*`, drive the CLI via `typer.testing.CliRunner` with
  `--server-url http://<httpserver>`, and assert on `--json` output and `check` exit codes.
  Failure paths covered: unhealthy datasource → exit 2, no dashboards → exit 2, 401 → exit 2.
- **Live (secondary):** `just grafana-check centralized_monitoring` against a running
  cluster must exit 0 (optionally asserted from `tests/testinfra/`).

## Justfile

```
just grafana-check CLUSTER              # check → exit code
just grafana-datasources CLUSTER        # list datasources
just grafana-dashboards CLUSTER         # list dashboards
```
Mirror the `heimdall-*` recipe shape: `uv run clusters/<CLUSTER>/scripts/grafana_cli.py <cmd> --cluster <CLUSTER>`.

See also [`specs/cli-prometheus.md`](cli-prometheus.md), [`specs/cli-openobserve.md`](cli-openobserve.md).
