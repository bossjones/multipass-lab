# Spec: Vaultwarden verification CLI (`vaultwarden-cli`)

## Context

`clusters/centralized_pki` runs **Vaultwarden** (`vaultwarden/server:1.32.0`) on the
`services` VM behind Traefik at `https://warden.<domain>` (Bitwarden-compatible vault). The
CLI reaches it **through Traefik** at the services VM's IP with a `Host: warden.<domain>`
header (no laptop-side DNS needed).

This spec designs `vaultwarden_cli.py` — a **uv single-file CLI** for a liveness `check`,
per the repo conventions in `CLAUDE.md`.

### Library choice

Vaultwarden ships no read SDK; the CLI uses [`httpx`](https://www.python-httpx.org/). Its
`/alive` endpoint returns a bare RFC3339 timestamp (not JSON). `WEBSOCKET_ENABLED` is gone
as of ≥1.29 (WebSocket shares the HTTP port). TLS verification defaults **off** (`--insecure`).

## Objective

Ship `vaultwarden_cli.py` (introspection + `check`), wired via `just vaultwarden-check`,
covered by a hermetic pytest suite (in-process HTTP server, no VM).

## Architecture

```
  operator laptop                        centralized-pki-services VM (Traefik :443)
  ┌───────────────────────────┐  HTTPS  ┌─────────────────────────────────────────┐
  │ vaultwarden_cli.py (uv/httpx)│ ─────► │ Traefik ─Host: warden.<domain>─► Vaultwarden│
  │  Host: warden.<domain>        │        │   /alive   /api/version                 │
  └───────────────────────────┘         └─────────────────────────────────────────┘
```

## Command surface

Global options: `--cluster`, `--server-url` / `$VAULTWARDEN_URL`, `--json`, `--timeout`,
`--insecure/--secure` (default insecure).

| Subcommand | Vaultwarden endpoint | Purpose |
|---|---|---|
| `alive` | `GET /alive` | 200 + timestamp liveness |
| `version` | `GET /api/version` | best-effort version (some builds 404) |
| `check` | alive (+ version, informational) | assert & exit nonzero |

## `check` semantics (exit 0 pass / 2 fail)

1. **Vaultwarden alive** — `GET /alive` → `200`.
2. **Version** — informational; `skip` on `404` (not all builds expose it), else `pass`/`fail`.

Any `fail` → exit 2. Connection refused → a single `fail` row + exit 2.

## Testing

- **Hermetic (primary, TDD):** `clusters/centralized_pki/tests/vaultwarden/` — `pytest-httpserver`
  serves canned `/alive` + `/api/version`; `CliRunner` drives with `--server-url`. Failure
  paths: `/alive` 503 → exit 2, `/api/version` 404 → `version` skip but overall pass,
  connection refused → exit 2.
- **Live (secondary):** `just vaultwarden-check centralized_pki` exits 0.

## Justfile

```
just vaultwarden-check CLUSTER   # check → exit code
```

See also [`cli-stepca.md`](cli-stepca.md), [`cli-authelia.md`](cli-authelia.md),
[`cli-tls.md`](cli-tls.md), [`centralized_pki.md`](centralized_pki.md).
