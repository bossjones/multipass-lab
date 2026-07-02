# Spec: OpenObserve Log Dashboards

## Context

`clusters/centralized_monitoring` ships logs into **OpenObserve**
(`public.ecr.aws/zinclabs/openobserve:latest`, server VM `http://<server>:5080`, org
`default`, root creds `admin@example.com` / `Complexpass#123`) across six streams — but has
**zero OpenObserve-native dashboards**. Every dashboard-as-code in the repo today is Grafana
JSON, and Grafana wires OpenObserve only as a **Prometheus-type** (PromQL) datasource
(`uid: openobserve`, `specs/dashboards.md:27`). That datasource can query the `metrics` stream
but **cannot** query the log streams — Grafana has no SQL/log surface into OpenObserve here. So
log-analysis dashboards (error triage, per-host, cause/effect correlation, volume overview)
**must be OpenObserve-native**: authored as OpenObserve dashboard JSON and loaded through its
`/api/{org}/dashboards` API.

This is greenfield. The goal is a dashboard set that lets you answer, at a glance: *what is my
log volume and where is it coming from*, *what is erroring right now and what does it say*,
*which host/container/pod is noisy*, and *did a log-error spike line up with a metric/trace
event* — using only the data the stack ingests today.

### Streams & the thin-schema reality

Logs are ingested by the OTel Collector filelog receivers with **no resource/transform
enrichment** — there are no parsed `severity` / `hostname` / `program` fields. Syslog is stored
as the raw line in `body`. Dashboards therefore lean on OpenObserve **full-text search**
(`match_all('error')`) and SQL over `body`, and treat **stream = host/source** as the primary
segmentation. (An optional enrichment appendix below describes how to upgrade to structured
fields.)

| Stream | Type | Source | Key queryable fields |
|---|---|---|---|
| `host_logs` | logs | server `/var/log/syslog` | `_timestamp`, `body`, `log_file_path` |
| `container_logs` | logs | server Docker json-file logs | `_timestamp`, `body`, `stream` (stdout/stderr), `time`, `log_file_path` |
| `otlp_logs` | logs+traces | apps pushing OTLP `:4317`/`:4318` | `_timestamp`, `body`, app-supplied attrs, trace fields |
| `k0s_host` | logs | k0s `/var/log/syslog` | `_timestamp`, `body`, `log_file_path` |
| `k0s_pods` | logs | k0s pod logs (`container` operator) | `_timestamp`, `body`, `k8s_namespace_name`, `k8s_pod_name`, `k8s_container_name` |
| `metrics` | metrics | Prometheus `remote_write` (both VMs) | PromQL series (`node_*`, `container_*`, …) |

> **Field names must be confirmed live** — the exact OpenObserve column names (dot→underscore
> flattening of OTLP attributes, e.g. `log.file.path` → `log_file_path`) can only be verified
> against a running instance. This is **implementation task 0** (`openobserve_cli.py streams` +
> a `SELECT * FROM <stream> LIMIT 1`), and the field table above must be reconciled before
> panel queries are finalized. Source of truth for stream names:
> `tests/testinfra/test_openobserve_ingest.py` and `docs/endpoints.md`.

## Design principles

1. **One dashboard = one analysis question.** Overview, error triage, per-host, containers,
   pods, correlation — no kitchen-sink boards.
2. **Full-text first, degrade gracefully.** Error/warn detection uses `match_all('error')` /
   `match_all('warn')` and SQL `LIKE` over `body` — no dependency on parsed severity. If the
   optional enrichment lands, panels can switch to a `severity` filter without restructuring.
3. **Time bucketing via `histogram(_timestamp)`.** All timeseries `GROUP BY histogram(_timestamp)`
   so OpenObserve chooses a sensible bucket for the selected range. Timestamps are µs-epoch.
4. **Stream = host/source.** "Per-host" maps to per-stream (`host_logs`=server, `k0s_host`=k0s);
   `container_logs` splits further by `log_file_path`, `k0s_pods` by `k8s_*`.
5. **Idempotent import.** Each dashboard carries a stable `title` and folder so re-importing
   updates in place rather than duplicating (see provisioning below).
6. **Correlation is a mixed board.** The cause/effect dashboard combines SQL log panels and
   PromQL metric panels on a shared time picker, plus a traces panel over `otlp_logs`, so a
   human can eyeball cause→effect across all three signals in one view.

## Folder taxonomy

| Folder | Purpose |
|---|---|
| `Logs` | Day-to-day log analysis — volume, errors, per-host, containers, pods. |
| `Correlation` | Cross-signal boards that line logs up against metrics and traces. |

## Dashboard inventory

Files live under `clusters/centralized_monitoring/openobserve/dashboards/<Folder>/*.json`
(versioned in git, loaded via the dashboards API — **not** cloud-init).

| File | Title | Purpose / key panels |
|---|---|---|
| `Logs/log-overview.json` | **Log Overview** | Total ingest at a glance: stacked volume-by-stream timeseries, ingest rate, 24h total stat tiles, top noisy sources table (`log_file_path`). |
| `Logs/error-triage.json` | **Error Triage** | Flagship. Error/warn count timeseries across streams; error rate by stream (bar); recent-errors table; **top error messages** (`GROUP BY body ORDER BY count DESC`). |
| `Logs/per-host.json` | **Per-Host / Per-Stream** | `$stream` variable; volume + error split for the selected host/stream, recent drill table. |
| `Logs/container-logs.json` | **Container Logs** | Volume + errors by container (derived from `log_file_path`), stdout vs stderr split (`stream`), recent table. |
| `Logs/k0s-pods.json` | **Kubernetes Pod Logs** | Volume by `k8s_namespace_name` / `k8s_pod_name`, per-pod error table, `$namespace` variable. |
| `Correlation/cause-effect.json` | **Cause & Effect** | Shared-time board: log-error spikes (SQL) beside node CPU / mem / disk (PromQL over `metrics`) and a recent-traces panel (`otlp_logs`), for eyeballing cause→effect. |

Representative queries (log panels are SQL over `_search`; metric panels are PromQL):

```sql
-- Error volume over time (any log stream)
SELECT histogram(_timestamp) AS ts, count(*) AS errors
FROM host_logs WHERE match_all('error') GROUP BY ts ORDER BY ts;

-- Top recurring error messages
SELECT body, count(*) AS n
FROM host_logs WHERE match_all('error') GROUP BY body ORDER BY n DESC LIMIT 20;

-- Container log volume by source (derive container from file path)
SELECT log_file_path, count(*) AS n
FROM container_logs GROUP BY log_file_path ORDER BY n DESC LIMIT 20;

-- Pod errors by namespace/pod
SELECT k8s_namespace_name, k8s_pod_name, count(*) AS n
FROM k0s_pods WHERE match_all('error') GROUP BY k8s_namespace_name, k8s_pod_name
ORDER BY n DESC LIMIT 20;
```

```promql
# Correlation board metric overlays (metrics stream, PromQL API)
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes
```

> OpenObserve dashboard JSON follows OpenObserve's own schema (v5-style: `version`,
> `dashboardId`/`title`, `panels[]` with `queryType` `sql`|`promql`, `layouts`, `variables`).
> Confirm the exact shape against the running version when authoring — the image is `:latest`
> (unpinned). Easiest authoring path: build one board in the UI, export its JSON, then
> templatize.

## Provisioning mechanics (CLI, on-demand)

There is no cloud-init hook for OpenObserve dashboards (unlike Grafana's drop-a-file sweep);
they are pushed to the API post-boot. This reuses the existing host-run CLI conventions
(`openobserve_cli.py`, `_obs_common`), mirroring how `just locust` / `just openobserve-check`
work.

New `openobserve_cli.py dashboards` sub-typer (all via the existing basic-auth `httpx` client,
org default `default`, server resolved by `_obs_common.resolve_target`):

| Subcommand | Endpoint | Purpose |
|---|---|---|
| `dashboards list` | `GET /api/{org}/dashboards` | list installed dashboards (rich table; `--json`) |
| `dashboards import [PATH]` | `GET/POST /api/{org}/folders` + `POST /api/{org}/dashboards?folder=<id>` | load every `*.json` under PATH (default: the repo dashboards dir); ensure folder, upsert by title |
| `dashboards delete ID` | `DELETE /api/{org}/dashboards/<id>` | remove a dashboard |

`import` is **idempotent**: it lists existing dashboards, and for each file updates the
matching title in place (or creates it), so re-running never duplicates.

## `check` semantics (exit 0 pass / 2 fail)

Add `--require-dashboards` to `openobserve_cli.py check`: after the existing health/auth/stream
checks, assert each expected dashboard title resolves via `GET /api/{org}/dashboards`. Missing
any → **fail** → exit 2. Opt-in (like `--require-streams`) so a fresh cluster without dashboards
imported yet isn't a false negative. Wired into `just verify-api`.

## Testing

Mirrors the repo's hermetic-first split.

- **Hermetic (primary, pytest-httpserver)** — `tests/openobserve/test_openobserve_dashboards_cli.py`,
  in the existing `tests/openobserve/` uv project (`pythonpath = ["../../scripts"]`). Serve
  canned `/api/{org}/dashboards` and `/api/{org}/folders` via `pytest-httpserver`; drive the CLI
  with `--server-url`; assert: `list`/`import`/`delete` hit the right paths and send
  `Authorization: Basic …`; `import` reads the JSON dir and POSTs each file; `import` upserts
  (no duplicate POST when the title already exists); `check --require-dashboards` returns exit 0
  when all present and exit 2 when one is missing. Reuse the `_server(...)` / `_run(...)`
  helpers from `test_openobserve_cli.py`.
- **JSON validity (hermetic)** — a test asserts every `openobserve/dashboards/**/*.json` parses
  and carries the required keys (`title`, `panels`), the OpenObserve parity of the Grafana
  `jq empty` check.
- **Live (secondary, testinfra)** — `tests/testinfra/test_openobserve_dashboards.py`: after
  `just openobserve-dashboards`, `GET /api/default/dashboards` on the server contains the six
  expected titles; flag-gated on `enable_openobserve`. Panel-level data assertions are out of
  scope (flaky); `just open` + the OpenObserve UI cover visual confirmation.

## Optional: structured-field enrichment (appendix, not in scope unless opted in)

The dashboards work on the raw-`body` schema, but every error/host panel improves if syslog is
parsed. To upgrade, add OTel operators/processors to
`cloud-init/otel/collector-config.yaml.tftpl` and `k0s-collector-config.yaml.tftpl`:

- A `regex_parser` (or `syslog_parser`) on the `filelog/host` operators to extract `severity`,
  `hostname`, `program`, and the clean message.
- A `transform`/`resource` processor to promote `severity` and `hostname` to first-class fields.

Panels then filter by `severity = 'error'` / group by `hostname` instead of `match_all` and
per-stream. **This edits `.tftpl` and therefore requires `just recreate`** (a plain `just up`
silently reuses the old cloud-init — see `CLAUDE.md` / `specs/ntp.md`). Left as a follow-up spec
unless requested.

## Justfile

```
just openobserve-dashboards CLUSTER        # import all dashboards from the repo dir
just openobserve-dashboards-list CLUSTER   # list installed dashboards
```

Both resolve the server IP via `tofu output` through `_obs_common`, exactly like the other
`openobserve-*` recipes.

Validation commands: `cd clusters/centralized_monitoring/tests/openobserve && uv run pytest -v`
(hermetic), `just up centralized_monitoring` + `just openobserve-dashboards centralized_monitoring`
+ `just verify centralized_monitoring` (live), `just verify-api centralized_monitoring`
(`check --require-dashboards`), `just open centralized_monitoring` then the OpenObserve UI on
`:5080` (visual).

See also [`specs/cli-openobserve.md`](cli-openobserve.md), [`specs/dashboards.md`](dashboards.md),
[`specs/openobserve.md`](openobserve.md).
