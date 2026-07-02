# Spec: Authelia verification CLI (`authelia-cli`)

## Context

`clusters/centralized_pki` runs **Authelia** (`authelia/authelia:4.38`) on the `services`
VM behind Traefik at `https://auth.<domain>` — forward-auth SSO with a file backend (one
user) that gates Vaultwarden's `/admin`. Authelia's `:9091` is only `expose`d inside the
compose network, so the CLI reaches it **through Traefik** at the services VM's IP with a
`Host: auth.<domain>` header (no laptop-side DNS needed).

This spec designs `authelia_cli.py` — a **uv single-file CLI** for introspection and a
CI-friendly `check`, per the repo conventions in `CLAUDE.md`.

### Library choice

Authelia ships no read SDK; the CLI uses [`httpx`](https://www.python-httpx.org/). Traefik
serves a step-ca / LE-staging cert, so TLS verification defaults **off** (`--insecure`).

## Objective

Ship `authelia_cli.py` (introspection + `check`), wired via `just authelia-check`, covered
by a hermetic pytest suite (in-process HTTP server, no VM).

## Architecture

```
  operator laptop                       centralized-pki-services VM (Traefik :443)
  ┌─────────────────────────┐  HTTPS   ┌────────────────────────────────────────┐
  │ authelia_cli.py (uv/httpx)│ ──────► │ Traefik ──Host: auth.<domain>──► Authelia│
  │  Host: auth.<domain>      │         │   /api/health   /api/authz/forward-auth │
  └─────────────────────────┘          └────────────────────────────────────────┘
```

The CLI resolves the services IP + `domain` from `tofu output` (or `--server-url`).

## Command surface

Global options: `--cluster`, `--server-url` / `$AUTHELIA_URL`, `--json`, `--timeout`,
`--insecure/--secure` (default insecure).

| Subcommand | Authelia endpoint | Purpose |
|---|---|---|
| `health` | `GET /api/health` | liveness |
| `check` | health + forward-auth | assert & exit nonzero |

## `check` semantics (exit 0 pass / 2 fail)

1. **Authelia health** — `GET /api/health` status `< 400`.
2. **Forward-auth enforcing** — `GET /api/authz/forward-auth` returns `401`/`403`/redirect
   for an unauthenticated request (a `404` means it's misconfigured/absent → fail).

Any `fail` → exit 2. Connection refused → a single `fail` row + exit 2.

## Testing

- **Hermetic (primary, TDD):** `clusters/centralized_pki/tests/authelia/` — `pytest-httpserver`
  serves canned `/api/health` + `/api/authz/forward-auth`; `CliRunner` drives with
  `--server-url` (domain empty → no `Host` header). Failure paths: health 5xx → exit 2,
  forward-auth 404 → exit 2, connection refused → exit 2.
- **Live (secondary):** `just authelia-check centralized_pki` exits 0.

## Justfile

```
just authelia-check CLUSTER   # check → exit code
```

See also [`cli-stepca.md`](cli-stepca.md), [`cli-vaultwarden.md`](cli-vaultwarden.md),
[`cli-tls.md`](cli-tls.md), [`centralized_pki.md`](centralized_pki.md).
