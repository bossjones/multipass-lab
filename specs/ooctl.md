# `ooctl` — async OpenObserve log-tailing CLI

## Context

`ooctl` is a standalone CLI that tails logs from an OpenObserve instance in real
time — modeled on [`o2-cli`](https://github.com/openobserve/o2-cli): a YAML
**profiles** config drives the connection. It lives as its own **uv project** in
`tools/ooctl/` so it can later be lifted into its own repo (hence a real `src/`
package, not the repo's PEP 723 single-file pattern). It is **async-first**
(`httpx.AsyncClient` + `asyncio`) and built **TDD** (pytest + pytest-mock +
pytest-asyncio + pytest-httpserver), with opt-in integration tests against a live
`centralized_monitoring` cluster.

### Key facts

- **OpenObserve runs only in `centralized_monitoring`** (server VM, `:5080`,
  `admin@example.com` / `Complexpass#123`, org `default`). `centralized_logging`
  has no OpenObserve endpoint. Integration tests target `centralized_monitoring`.
- **No push/subscribe for new logs.** Real-time `tail -f` = **sliding-window
  polling** on the `_timestamp` column (microseconds since epoch, field name
  `_timestamp`), advancing `start_time` past the last-seen timestamp each poll.
- **Endpoints** (all org-scoped, HTTP Basic auth `base64(email:password)`):
  - `POST /api/{org}/_search` — body `{"query":{"sql","start_time","end_time","from","size"}}`, µs times. Response `{"hits":[...], "total", ...}`.
  - `POST /api/{org}/_search_stream` — same body; response `Content-Type: text/event-stream`, SSE frames `event: <type>\ndata: <json>\n\n`. Event types: `search_response_metadata`, `search_response_hits` (`{"hits":[...]}`), `progress`, `error`, `done`, `cancelled`. Used for **bulk one-shot** search.
  - `GET /api/{org}/streams[?type=logs]` — list streams.
  - `GET /healthz` — liveness (unauthenticated).

## Objective

`uv run ooctl logs tail -f --profile default` streams live logs from OpenObserve
to the terminal, plus `logs search`, `configure list/add`, `streams list`, and
`health`; a committed `example.config.yaml` with lab defaults; a
`tools/ooctl/justfile`; unit tests (hermetic) and opt-in integration tests.

## Solution Approach

- **Package** (`src/ooctl/`), typer app with global `--config`/`--profile` on the
  callback (mirrors `openobserve_cli.py`'s `Options`→resolved-context split).
- **Config**: pydantic v2 models load `~/.ooctl/config.yaml` (`--config` flag or
  `$OOCTL_CONFIG` override); `profiles:` map exactly like o2-cli. Per-field env
  overrides (`OOCTL_ENDPOINT/ORG/USERNAME/PASSWORD`) let the lab justfile inject
  the DHCP IP without hardcoding tofu into the standalone tool.
- **Async client** (`httpx.AsyncClient`, basic auth): `search()`, `search_stream()`
  (SSE parser → async iterator of hits), `streams()`, `health()`.
- **Follow loop** (`tail.py`): asyncio **producer/consumer** (overlap network I/O
  with rendering, and allow *concurrent* multi-stream tailing via `asyncio.gather`).
  Producer polls `_search` on an interval, advances the `_timestamp` window, dedups
  the boundary bucket, and enqueues hits; consumer renders from the `asyncio.Queue`.
- Typer commands are sync shells that call `asyncio.run(_impl(...))`.

## Layout

```
tools/ooctl/
  pyproject.toml            # hatchling+uv-dynamic-versioning, src layout, [project.scripts] ooctl = "ooctl.cli:app"
  README.md
  justfile                  # install/lint/test/tail/search/streams/health recipes
  example.config.yaml       # committed lab defaults (profiles: default: ...)
  .gitignore
  src/ooctl/__init__.py
  src/ooctl/__main__.py      # python -m ooctl
  src/ooctl/cli.py           # typer app + callback + subcommands
  src/ooctl/config.py        # pydantic Profile/Config models; load ~/.ooctl/config.yaml; env overrides
  src/ooctl/client.py        # OpenObserveClient(httpx.AsyncClient): search/search_stream(SSE)/streams/health
  src/ooctl/sse.py           # SSE frame parser
  src/ooctl/tail.py          # async follow loop: window advance + dedup + producer/consumer queue
  src/ooctl/render.py        # rich rendering; µs->ISO timestamp; --json passthrough
  tests/conftest.py
  tests/test_config.py
  tests/test_sse.py
  tests/test_client.py
  tests/test_tail.py
  tests/test_cli.py
  tests/test_render.py
  tests/integration/test_live_monitoring.py   # @pytest.mark.integration, skipped by default
```

## Testing Strategy

- **Hermetic unit (default):** pytest-httpserver simulates OpenObserve REST + SSE;
  pytest-mock stubs the client for `tail.py` loop logic; `CliRunner` drives the CLI
  with a tmp config. `pytest-asyncio` (`asyncio_mode=auto`). Edge cases:
  empty/partial windows, boundary dedup, SSE `error`/`done`, auth 401, missing
  profile/config, non-JSON `/healthz`, malformed SSE frame.
- **Opt-in integration:** `-m integration` against live `centralized_monitoring`;
  auto-skip when the cluster/endpoint is unavailable.

## Acceptance Criteria

- `uv run ooctl logs tail -f --profile default` streams new logs live and follows
  until Ctrl-C.
- `logs search`, `configure list/add`, `streams list`, `health` work; `--json`
  gives machine-readable output; `health` exits nonzero on failure.
- Config loads from `~/.ooctl/config.yaml` (o2-cli `profiles:` schema); `--config`,
  `$OOCTL_CONFIG`, and `OOCTL_*` field env vars override.
- `example.config.yaml` committed with lab defaults.
- Standalone uv project (src layout) — no dependency on the repo's `_obs_common.py`
  or cluster tooling; portable to its own repo.
- `tools/ooctl/justfile` with the recipes above.
- Client + follow loop are `asyncio`/`httpx.AsyncClient`-based.

## Validation Commands

Run from `tools/ooctl/`:

- `uv sync`
- `uv run ruff check . && uv run ruff format --check .`
- `uv run pytest` (integration auto-excluded)
- `uv run ooctl --help` / `uv run ooctl logs tail --help`
- Live (after `just up centralized_monitoring`, from repo root):
  `OOCTL_ENDPOINT=http://$(tofu -chdir=clusters/centralized_monitoring output -raw server_ipv4):5080 uv run --project tools/ooctl ooctl health --profile default`
- `uv run pytest -m integration` (with the cluster up)

## Notes

- **Why polling for `-f`:** OpenObserve OSS has no live-subscribe; `_search_stream`
  streams a *single query's* results, not future logs. Sliding-window polling on
  `_timestamp` (µs) is the robust follow mechanism; `_search_stream` (SSE) is used
  for bounded/bulk `logs search`.
- **Concurrency:** asyncio producer/consumer overlaps network latency with
  rendering; multiple `--stream` targets tail concurrently via `asyncio.gather`.
