# Spec: OpenObserve verification CLI (`openobserve-cli`)

## Context

`clusters/centralized_monitoring` deploys **OpenObserve**
(`public.ecr.aws/zinclabs/openobserve:latest`) on the server VM at `http://<server>:5080`
(root creds `admin@example.com` / `Complexpass#123`; OpenObserve rejects weak passwords,
hence the fixed strong value in `main.tf`). It is the sink for the OTel Collector's
**traces → OpenObserve** and **logs → OpenObserve** pipelines, and exposes a
PromQL-compatible API that Grafana uses as a datasource.

There is currently **no** programmatic check of OpenObserve anywhere — the testinfra suite
does not query it. This spec adds a host-side CLI to inspect streams, run searches, hit the
PromQL API, and `check` health + auth, with a CI exit code.

### Library choice

The requested `openobserve-python-sdk` is an **OTel ingestion** library (it *sends* logs/
metrics/traces); it has no read/query surface. OpenObserve ships **no official read SDK**,
so verification uses raw [`httpx`](https://www.python-httpx.org/) against its REST API.
`openobserve-python-sdk` is reserved for the opt-in **e2e loop** (push sample logs → poll
`search` until they land → assert round-trip) — the cleanest of the three e2e loops, since
logs already route here.

## Objective

Ship `openobserve_cli.py` with introspection subcommands and a CI-friendly `check`, wired via
`just openobserve-*`, covered by a hermetic pytest suite (in-process HTTP server) plus an
optional live smoke check.

## Architecture

```
  operator laptop                             centralized-monitoring-server VM
  ┌────────────────────────┐  HTTP :5080     ┌──────────────────────────────┐
  │ openobserve_cli.py (uv) │ ──────────────► │ openobserve container        │
  │  httpx (basic auth)     │                 │  /healthz                     │
  │  _obs_common (tofu → ip)│                 │  /api/{org}/streams           │
  │                         │ ◄────────────── │  /api/{org}/_search (POST)    │
  └────────────────────────┘                 │  /api/{org}/prometheus/api/v1 │
                                              └──────────────────────────────┘
```

Default org is `default`. All calls except `/healthz` use HTTP basic auth.

## Command surface

Global options (from `_obs_common`): `--cluster` (default `centralized_monitoring`),
`--server-url` / `$OPENOBSERVE_URL`, `--user` / `$OPENOBSERVE_USER`
(default `admin@example.com`), `--password` / `$OPENOBSERVE_PASSWORD`
(default `Complexpass#123`), `--org` (default `default`), `--json`, `--timeout`, `--insecure`.

| Subcommand | Endpoint | Purpose |
|---|---|---|
| `health` | `GET /healthz` | liveness (no auth) |
| `streams [--type logs\|metrics\|traces]` | `GET /api/{org}/streams` | list ingest streams |
| `search SQL [--start --end --size]` | `POST /api/{org}/_search` | SQL over a stream |
| `query PROMQL` | `GET /api/{org}/prometheus/api/v1/query` | PromQL-compatible metrics |
| `orgs` | `GET /api/organizations` | list orgs |
| `check [--require-streams]` | `/healthz` + `streams` | assert & exit nonzero |

`search` body: `{"query": {"sql": "<SQL>", "start_time": <µs>, "end_time": <µs>, "size": N}}`.
Introspection prints a rich table, or clean `json.dumps` under `--json`.

## `check` semantics (exit 0 pass / 2 fail)

1. **Health** — `GET /healthz` returns 2xx.
2. **Auth works** — `GET /api/{org}/streams` returns 2xx (401/403 → **fail**).
3. **Streams present** — reported always; a **fail** only with `--require-streams`
   (a fresh cluster has no streams until telemetry flows, so this is opt-in to avoid
   false negatives). With `--require-streams`, expect ≥ 1 stream.

Any `fail` → exit 2. Connection refused → single `fail` row + exit 2.

## e2e loop (opt-in, `check --e2e` or `just openobserve-e2e`)

Push a batch of sample log records via `openobserve-python-sdk` (or a direct
`POST /api/{org}/{stream}/_json`), then `poll()` a `search` over that stream until the
records appear (or timeout), and assert the round-trip. Validates the ingest→query pipeline
end to end.

## Testing

- **Hermetic (primary, TDD):** `clusters/centralized_monitoring/tests/openobserve/` — mini
  uv project (`pythonpath = ["../../scripts"]`, deps `pytest, pytest-httpserver,
  pytest-mock, pytest-cov, pytest-randomly, typer, rich, httpx`). Tests serve canned
  `/healthz`, `/api/{org}/streams`, `/api/{org}/_search`,
  `/api/{org}/prometheus/api/v1/query` via `pytest-httpserver`, drive the CLI with
  `--server-url`, and assert `--json` output, basic-auth header, and `check` exit codes.
  Failure paths: 401 on `streams` → exit 2; `--require-streams` with empty list → exit 2;
  connection refused → exit 2.
- **Live (secondary):** `just openobserve-check centralized_monitoring` exits 0 against a
  running cluster.

## Justfile

```
just openobserve-check CLUSTER                        # check → exit code
just openobserve-streams CLUSTER                      # list streams
just openobserve-search CLUSTER 'SELECT * FROM ...'   # SQL search
```

See also [`specs/cli-grafana.md`](cli-grafana.md), [`specs/cli-prometheus.md`](cli-prometheus.md).
