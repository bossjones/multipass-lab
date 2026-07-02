# Spec: Prometheus verification CLI (`prometheus-cli`)

## Context

`clusters/centralized_monitoring` deploys **Prometheus** (`prom/prometheus:latest`) on the
server VM at `http://<server>:9090` (no auth — lab by design). It scrapes ~13 default jobs
(`node`, `cadvisor`, `kubelet`, `blackbox`, `selfmetrics`, …; see `docs/endpoints.md`),
each gated by an `enable_*` flag, and ships two alert rules (`TargetDown`,
`BlackboxProbeFailed`) routed through Alertmanager.

The live testinfra suite already curls `/api/v1/targets` and `/api/v1/query` **over SSH on
the VM**. This spec adds a host-side CLI to run PromQL, inspect target/alert health, and
`check` that scrape targets are up — from the laptop, with a CI exit code.

### Library choice

The requested `prometheus/client_python` is an **instrumentation** library (it exposes
`/metrics` from an app; it cannot query). For read/verify we use
[`prometheus-api-client`](https://pypi.org/project/prometheus-api-client/)
(`PrometheusConnect`), which wraps the Prometheus HTTP API: `custom_query`,
`custom_query_range`, `get_label_values`, `all_metrics`, and `get_targets`
(`/api/v1/targets`). It has **no** wrapper for `/api/v1/alerts` or `/api/v1/rules`, so those
two use the stdlib GET helper in `_obs_common`. `prometheus/client_python` is reserved for
the (stretch) e2e loop — noted below as optional since the cluster has no Pushgateway.

## Objective

Ship `prometheus_cli.py` with introspection subcommands and a CI-friendly `check`, wired via
`just prometheus-*`, covered by a hermetic pytest suite (in-process HTTP server) plus an
optional live smoke check.

## Architecture

```
  operator laptop                             centralized-monitoring-server VM
  ┌────────────────────────┐  HTTP :9090     ┌──────────────────────────────┐
  │ prometheus_cli.py (uv)  │ ──────────────► │ prometheus container         │
  │  prometheus-api-client  │  (no auth)      │  /api/v1/query[_range]        │
  │  _obs_common (tofu → ip,│                 │  /api/v1/targets              │
  │   enabled_exporters)    │ ◄────────────── │  /api/v1/{alerts,rules,label} │
  └────────────────────────┘                 └──────────────────────────────┘
```

`enabled_exporters` from the tofu output makes `check` job-aware — a disabled feature is
**skipped, not failed** (same contract as `tests/testinfra/`).

## Command surface

Global options (from `_obs_common`): `--cluster` (default `centralized_monitoring`),
`--server-url` / `$PROMETHEUS_URL`, `--json`, `--timeout`, `--insecure`. (Prometheus is
unauthenticated; `--user`/`--password` accepted but unused.)

| Subcommand | Endpoint | Purpose |
|---|---|---|
| `query PROMQL` | `custom_query()` → `/api/v1/query` | instant PromQL |
| `query-range PROMQL --start --end --step` | `custom_query_range()` | range query |
| `targets [--state active]` | `get_targets()` → `/api/v1/targets` | per-target `health` |
| `alerts` | stdlib GET `/api/v1/alerts` | firing/pending alerts |
| `rules` | stdlib GET `/api/v1/rules` | alerting/recording rules |
| `labels` / `label-values LABEL` | `get_label_names()` / `get_label_values()` | label discovery |
| `metrics` | `all_metrics()` | metric name list |
| `check` | `up` query + `get_targets()` | assert & exit nonzero |

Introspection prints a rich table, or clean `json.dumps` under `--json`.

## `check` semantics (exit 0 pass / 2 fail)

1. **Prometheus alive** — `custom_query("up")` returns ≥ 1 series.
2. **No down targets** — `get_targets()` active targets: **fail** if any has
   `health == "down"`; report per-job up/down counts.
3. **Expected jobs present (flag-aware)** — when `enabled_exporters` is available, each
   expected job (mapped from its `enable_*` flag) must have ≥ 1 active target; a job whose
   flag is off is `skip`. In `--server-url` mode (no tofu, no flags) this step is `skip` and
   only steps 1–2 apply.

Any `fail` → exit 2. Connection refused → single `fail` row + exit 2.

## e2e loop (opt-in / stretch)

`prometheus/client_python` is scrape-based and there is **no Pushgateway** in the cluster,
so a metric round-trip is documented but **not built by default**; it would require adding a
Pushgateway service or an ephemeral scrape target. Flagged `--e2e` for future work.

## Testing

- **Hermetic (primary, TDD):** `clusters/centralized_monitoring/tests/prometheus/` — mini
  uv project (`pythonpath = ["../../scripts"]`, deps `pytest, pytest-httpserver,
  pytest-mock, pytest-cov, pytest-randomly, typer, rich, prometheus-api-client`). Tests
  serve canned `/api/v1/{query,query_range,targets,alerts,rules,labels,label/*/values}` via
  `pytest-httpserver`, drive the CLI with `--server-url`, assert `--json` output and `check`
  exit codes. Failure paths: a `down` target → exit 2; connection refused → exit 2.
- **Live (secondary):** `just prometheus-check centralized_monitoring` exits 0 against a
  running cluster.

## Justfile

```
just prometheus-check CLUSTER                 # check → exit code
just prometheus-query CLUSTER 'up'            # instant PromQL
just prometheus-targets CLUSTER               # target health
```

See also [`specs/cli-grafana.md`](cli-grafana.md), [`specs/cli-openobserve.md`](cli-openobserve.md).
