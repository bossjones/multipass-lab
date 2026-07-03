# ooctl

Async CLI to **tail and search logs** from an [OpenObserve](https://openobserve.ai/)
instance. Modeled on [`o2-cli`](https://github.com/openobserve/o2-cli): a YAML
**profiles** config drives the connection.

Built async-first (`httpx.AsyncClient` + `asyncio`) so a `-f` follow overlaps
network I/O with rendering and can tail multiple streams concurrently.

## Install

Standalone [uv](https://docs.astral.sh/uv/) project (src layout):

```sh
cd tools/ooctl
uv sync
uv run ooctl --help
```

## Configure

Config lives at `~/.ooctl/config.yaml` by default (override with `--config` or
`$OOCTL_CONFIG`). The schema mirrors `o2-cli` — a `profiles:` map:

```yaml
profiles:
  default:
    endpoint: http://127.0.0.1:5080
    organization: default
    username: admin@example.com
    password: "Complexpass#123"
    timeout: 10        # optional (seconds)
    verify: true       # optional (TLS verification)
  dev:
    endpoint: https://dev.openobserve.com
    organization: dev-org
    username: dev-user@company.com
    password: dev-password
```

Copy [`example.config.yaml`](./example.config.yaml) to get started:

```sh
mkdir -p ~/.ooctl && cp example.config.yaml ~/.ooctl/config.yaml
```

Any field can be overridden at runtime with an env var — handy for injecting a
DHCP-assigned lab endpoint without editing the file:

| Env var             | Overrides            |
| ------------------- | -------------------- |
| `OOCTL_ENDPOINT`    | `endpoint`           |
| `OOCTL_ORG`         | `organization`       |
| `OOCTL_USERNAME`    | `username`           |
| `OOCTL_PASSWORD`    | `password`           |
| `OOCTL_CONFIG`      | config file location |

## Commands

```sh
ooctl configure list                     # list profiles (passwords redacted)
ooctl configure add staging --endpoint http://s:5080 --username u --password p

ooctl health                             # liveness probe (exit nonzero if down)
ooctl streams list [--type logs] [--json]

# one-shot bounded search (streaming SSE endpoint)
ooctl logs search --stream default --since 1h [--limit 100] [--json]
ooctl logs search --sql 'SELECT * FROM default ORDER BY _timestamp DESC'

# live tail
ooctl logs tail --stream default                 # one window then exit
ooctl logs tail -f --stream default              # follow new logs
ooctl logs tail -f --stream app --stream sys     # tail multiple streams at once
ooctl logs tail -f --since 30s --interval 1 --json
```

Global options (`--profile/-p`, `--config`) go **before** the command.

### How `-f` works

OpenObserve has no push/subscribe for new logs, so `-f` is **sliding-window
polling**: each `--interval` seconds it queries `[last_seen_timestamp, now]` on the
microsecond `_timestamp` column, deduplicating records that share the boundary
timestamp. `logs search` instead uses the streaming `_search_stream` (SSE)
endpoint for an efficient bounded fetch.

## Lab usage (multipass-lab)

OpenObserve runs in the `centralized_monitoring` cluster. The [`justfile`](./justfile)
resolves the server IP from `tofu output` and injects it via `$OOCTL_ENDPOINT`:

```sh
# from repo root
just up centralized_monitoring
# from tools/ooctl
just tail                 # tail -f the default stream against the live cluster
just search default 'SELECT * FROM default'
just streams
just health
```

## Tests

```sh
uv run pytest                 # hermetic unit tests (pytest-httpserver, no VMs)
uv run pytest -m integration  # live tests (needs a running OpenObserve)
```

Integration tests resolve the endpoint from `$OOCTL_ENDPOINT` or tofu and skip
cleanly if the cluster is down (`just test-int` wires the endpoint for you).
