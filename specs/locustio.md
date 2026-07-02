# Spec: Locust load generators (`locust-cli`)

## Context

Both lab clusters render dashboards that are only interesting when something is
producing traffic. Today that traffic is incidental — journald/system logs in
`centralized_logging`, exporter self-scrapes in `centralized_monitoring` — so
the Grafana/Prometheus/OpenObserve panels sit mostly idle. This spec adds a
[**Locust**](https://github.com/locustio/locust) load generator, **run from the
host on-demand**, that deliberately hits each cluster's ingest/query surfaces so
logs and metrics visibly flow into the dashboards (`just open <cluster>`).

Scope is a **host-run tool** (no in-cluster deployment): no `enable_locust`
flag, no cloud-init/compose changes, no new VMs. `just locust <cluster>`
resolves VM IPs from `tofu output`, points Locust at them, and opens the Locust
web UI so you can drive users/spawn-rate interactively while watching the target
cluster's dashboards fill in.

This conforms to the repo conventions in `CLAUDE.md`: uv single-file scripts
(PEP 723), host→VM target resolution via `tofu output`, the two-layer
(hermetic + testinfra) test split, and `just` recipes parametrized by cluster
folder name. It reuses `clusters/centralized_monitoring/scripts/_obs_common.py`
for target/credential resolution and `CheckReport`.

### Library choice

[`locust`](https://locust.io) (the PyPI package) is declared as a **uv
single-file dependency** in each `locust_cli.py` PEP 723 block. Rationale over a
hand-rolled `asyncio` loop or `k6`: Locust is Python-native (locustfiles are
plain Python, testable in-process with pytest), ships a **built-in web UI +
headless CSV reporting**, and — crucially for this lab — supports **arbitrary,
non-HTTP protocols** via custom `User` clients that fire
`self.environment.events.request.fire(...)` to feed the same stats engine. HTTP
targets use the built-in `HttpUser`/`FastHttpUser`; StatsD (UDP) and syslog
(TCP RFC5424) use small custom clients. `Faker` provides payload variety.

## Objective

Ship a `locust_cli.py` per cluster (uv single-file, Typer + rich) that wraps
`locust` with `tofu`-resolved targets, plus the locustfiles they drive, wired
via `just locust-*`, covered by a hermetic pytest suite (locustfile task unit
tests, no VMs) and an optional live post-load assertion in testinfra.

## Architecture

```
  operator laptop                                      running cluster VMs
  ┌───────────────────────────┐                        ┌───────────────────────────────┐
  │ just locust <cluster>      │                        │ centralized-monitoring-server │
  │  └─ locust_cli.py (uv)     │  HTTP :5080 _json  ──► │  OpenObserve ──┐              │
  │      _obs_common(tofu→ip)  │  HTTP :4318 /v1/*  ──► │  OTel Collector┤→ OpenObserve │
  │      locust master + web   │  UDP  :8125 statsd ──► │  statsd_exp ───┤→ Prometheus  │
  │      UI  http://:8089      │  HTTP :9090/:3000  ◄─► │  Prometheus/Grafana (query)   │
  └───────────────────────────┘                        └──────────────┬────────────────┘
                                                          data ────────► Grafana panels
  ┌───────────────────────────┐                        ┌───────────────────────────────┐
  │ just locust <cluster>      │  TCP :514 RFC5424  ──► │ centralized-logging-central   │
  │  └─ locust_cli.py (uv)     │  (custom socket client)│  syslog-ng listener           │
  │      SyslogTcpUser         │                        │  → /var/log/remote/<h>/<p>.log│
  └───────────────────────────┘                        └───────────────────────────────┘
```

Targets are resolved per cluster: `centralized_monitoring` from the
`server_ipv4` output; `centralized_logging` from the `hosts` output
(`.central.ipv4`). `--server-url`/env overrides `tofu output` (same precedence
as the existing CLIs).

## Command surface

Global options (on the Typer `@app.callback()`, resolved via `_obs_common`):
`--cluster` (default per script), `--server-url` / `$LOCUST_TARGET_URL`,
`--users` (peak concurrency), `--spawn-rate` (users/s), `--run-time` (e.g.
`30s`, `5m`; headless only), `--headless` / `--web` (default `--web`),
`--web-port` (default `8089`), `--json`, `--timeout`. Monitoring adds
`--user`/`--password` (OpenObserve basic auth, defaults `admin@example.com` /
`Complexpass#123`) and `--org` (default `default`).

| Subcommand | Purpose |
|---|---|
| `run` | launch Locust against the resolved host (web UI by default; headless with `--headless --run-time`) |
| `check` | short headless smoke run; assert requests fired and failure-ratio 0 → exit nonzero |
| `targets` | print the resolved endpoints (IP:port per target) as a table or `--json`; no load |

`run`/`check` shell out to `locust -f <locustfile> --host <resolved-base>`
(plus `--headless -u <users> -r <spawn> -t <run-time> --csv <tmp>` for
headless/check), streaming Locust's own output. `targets` resolves and prints
without launching Locust — the quick "did IP resolution work" probe.

### centralized_monitoring locustfile (`locustfiles/monitoring.py`)

Weighted `User` classes (select a subset per run via Locust tags / `--users`):

- **`OpenObserveIngestUser(HttpUser)`** — `POST /api/{org}/{stream}/_json` with
  basic auth, body a JSON array of synthetic records (`Faker`: `level`,
  `message`, `service`, `trace_id`, timestamp). Stream defaults to `loadtest`.
- **`OtlpUser(HttpUser)`** — `POST /v1/logs` (and optionally `/v1/traces`,
  `/v1/metrics`) to `:4318` with minimal **OTLP-JSON** payloads (example below).
  Traces → OpenObserve, metrics → Prometheus.
- **`StatsdUser(User)`** — custom UDP client to `:8125` sending StatsD lines
  (`loadtest.requests:1|c`, `loadtest.latency_ms:<n>|ms`), firing
  `events.request` per send. Surfaces at statsd_exporter `:9102/metrics` →
  Prometheus job `statsd`.
- **`QueryUser(HttpUser)`** — `GET :9090/api/v1/query?query=up` (Prometheus) and
  a Grafana `GET :3000/api/health` / datasource read; generates read traffic +
  request-rate metrics on the stack itself.

Because these classes span **different ports on the same host**, each `User`
sets its own `host` (or the client prefixes the port), all derived from the one
resolved `server_ipv4`.

Minimal OTLP-JSON log payload (`POST :4318/v1/logs`):

```json
{
  "resourceLogs": [{
    "resource": {"attributes": [
      {"key": "service.name", "value": {"stringValue": "locust-loadtest"}}
    ]},
    "scopeLogs": [{
      "logRecords": [{
        "timeUnixNano": "<ns>",
        "severityText": "INFO",
        "body": {"stringValue": "synthetic log from locust"}
      }]
    }]
  }]
}
```

### centralized_logging locustfile (`locustfiles/logging.py`)

- **`SyslogTcpUser(User)`** — a custom client holding a **persistent TCP
  socket** to `central:514`, writing **RFC5424**-framed messages (the listener
  sets `flags(syslog-protocol)`, so BSD/RFC3164 lines are rejected). Each send
  fires `events.request.fire(request_type="SYSLOG", name="rfc5424",
  response_time=<ms>, response_length=<bytes>)`; reconnects on socket error and
  reports it as a failure.

RFC5424 frame (octet-counted, as syslog-ng expects for TCP): `<PRI>1 TIMESTAMP
HOSTNAME APP-NAME PROCID MSGID STRUCTURED-DATA MSG`, e.g.

```
<134>1 2026-07-02T12:00:00.000Z locust-loadtest loadtest 1234 - - synthetic message
```

with an `<octet-count> ` length prefix per message (or `\n` framing if the
listener is switched to newline mode). Landed logs verify at
`/var/log/remote/locust-loadtest/loadtest.log` on `central`.

## `check` semantics (exit 0 pass / 2 fail)

Reuse `_obs_common.CheckReport` (`CHECK_FAIL_EXIT = 2`):

1. **Target resolved** — `tofu output` / override yields an IP:port (unresolved → **fail**).
2. **Load ran** — a short headless run (`--run-time 10s`, few users) completes and the parsed CSV shows **request count > 0**.
3. **No failures** — CSV failure count / ratio is **0** (any failed request → **fail**).

Any `fail` → exit 2. Connection refused / Locust nonzero exit → single `fail` row + exit 2.

## Testing

- **Hermetic (primary, TDD):** `clusters/<cluster>/tests/locust/` — mini uv
  project (`pythonpath = ["../../scripts", "../../scripts/locustfiles"]`, deps
  `pytest, pytest-httpserver, pytest-mock, pytest-cov, pytest-randomly, typer,
  rich, locust`). Import the locustfile classes and drive individual tasks
  against a `pytest-httpserver` (for HTTP users) or a stub UDP/TCP listener
  socket (for `StatsdUser`/`SyslogTcpUser`); assert request shape (path, method,
  basic-auth header, RFC5424 framing, StatsD line format) and that
  `events.request` fires. CLI tests use `typer.testing.CliRunner` with `locust`
  monkeypatched to a fake subprocess to assert arg construction and `check` exit
  codes (request>0 → 0; failures>0 → 2; unresolved target → 2). **No VMs, no
  real Locust run.**
- **Live (secondary):** extend `tests/testinfra/`. Logging: after a short
  headless `SyslogTcpUser` run, assert a unique token lands under
  `/var/log/remote/locust-loadtest/`. Monitoring: after a short ingest run,
  assert the `loadtest` OpenObserve stream row-count (or a Prometheus series)
  increased. Gate behind a marker so `just verify` stays fast by default.

## Justfile

```
just locust CLUSTER *FLAGS            # web UI run (localhost:8089) against resolved host
just locust-headless CLUSTER *FLAGS   # headless: pass -u/-r/-t via *FLAGS
just locust-check CLUSTER             # short smoke run → exit code
just locust-targets CLUSTER           # print resolved endpoints, no load
```

Each is `uv run {{cluster_root}}/{{CLUSTER}}/scripts/locust_cli.py --cluster
{{CLUSTER}} <cmd> {{FLAGS}}` (mirroring the `*-check` recipes; folder→VM name
maps underscores→hyphens as elsewhere). Optionally add `locust-check` to the
`verify-api` service loop once stable.

## Data-visibility mapping

Which target feeds which panel — open with `just open <cluster>`:

| Target | Endpoint | Lands in | Where to see it |
|---|---|---|---|
| OpenObserve ingest | `POST :5080/api/default/loadtest/_json` | OpenObserve `loadtest` stream | OpenObserve UI (`:5080`) + Grafana OpenObserve datasource |
| OTLP logs/traces | `POST :4318/v1/{logs,traces}` | OpenObserve (via OTel) | OpenObserve traces/logs + Grafana |
| OTLP metrics | `POST :4318/v1/metrics` | Prometheus (via OTel `:8888`) | Prometheus `:9090` + Grafana |
| StatsD | UDP `:8125` | statsd_exporter `:9102` → Prometheus `statsd` job | Grafana Platform dashboards |
| Query load | `GET :9090`, `:3000` | request-rate metrics on the stack | Grafana Instances/Platform |
| Syslog (logging) | TCP `:514` RFC5424 | `/var/log/remote/locust-loadtest/loadtest.log` | `just logs centralized_logging`; logging Grafana |

## See also

[`specs/cli-grafana.md`](cli-grafana.md), [`specs/cli-prometheus.md`](cli-prometheus.md),
[`specs/cli-openobserve.md`](cli-openobserve.md),
[`specs/centralized_monitoring.md`](centralized_monitoring.md),
[`specs/centralized_logging.md`](centralized_logging.md), and the endpoint
inventory `clusters/centralized_monitoring/docs/endpoints.md`.
