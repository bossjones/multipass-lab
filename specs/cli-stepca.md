# Spec: step-ca verification CLI (`stepca-cli`)

## Context

`clusters/centralized_pki` runs **step-ca** (`smallstep/step-ca`) on the `ca` VM at
`https://<ca>:9000` — a private internal CA with an **ACME** provisioner (`acme`) and a
password-protected **JWK** provisioner (`admin`, used by the services VM to issue Traefik's
cert directly). Its root/intermediate are generated at first boot.

Today the only programmatic check is the live testinfra suite (`curl` over SSH on the VM).
This spec designs `stepca_cli.py` — a **uv single-file CLI** run from the laptop for both
**introspection** and a CI-friendly **`check`** — following the repo conventions in
`CLAUDE.md` (uv single-file scripts, two-layer test split, folder-name Justfile recipes).

### Library choice

step-ca ships **no read SDK**, so the CLI talks to its HTTP API directly with
[`httpx`](https://www.python-httpx.org/). The `step`/`step-ca` binaries are not a Python
dependency. The shared stdlib-only `_pki_common.py` provides target resolution
(`tofu output` → `ca_ipv4`), the `CheckReport` accumulator, and `--json` output.

## Objective

Ship `stepca_cli.py` with introspection subcommands and a `check`, wired via `just
stepca-*`, covered by a hermetic pytest suite (in-process HTTP server, no VM).

## Architecture

```
  operator laptop                              centralized-pki-ca VM
  ┌────────────────────────┐  HTTPS :9000     ┌──────────────────────────────┐
  │ stepca_cli.py (uv/httpx)│ ───────────────► │ step-ca container            │
  │  _pki_common.resolve    │                  │  /health {"status":"ok"}     │
  │   (tofu output → ca_ipv4)│ ◄────────────── │  /provisioners  /roots.pem   │
  └────────────────────────┘                   └──────────────────────────────┘
```

step-ca serves a self-signed leaf on `:9000`, so verification defaults **off**
(`--insecure`); `--ca-cert /path/root_ca.crt` verifies strictly. The real chain assertion
lives in [`cli-tls.md`](cli-tls.md).

## Command surface

Global options (on the callback): `--cluster` (default `centralized_pki`), `--server-url` /
`$STEPCA_URL`, `--ca-cert`, `--json`, `--timeout`, `--insecure/--secure` (default insecure).

| Subcommand | step-ca endpoint | Purpose |
|---|---|---|
| `health` | `GET /health` | `{"status":"ok"}` liveness |
| `roots` | `GET /roots.pem` | fetch/inspect the CA root bundle |
| `provisioners` | `GET /provisioners` | list name/type |
| `check` | health + provisioners + roots | assert & exit nonzero |

## `check` semantics (exit 0 pass / 2 fail)

1. **CA health** — `GET /health` → `status == "ok"`.
2. **ACME provisioner** — `/provisioners` contains an entry of `type == "acme"`.
3. **Root cert served** — `/roots.pem` returns ≥ 1 `BEGIN CERTIFICATE`.

Any `fail` → exit 2. Connection refused → a single `fail` row + exit 2.

## Testing

- **Hermetic (primary, TDD):** `clusters/centralized_pki/tests/stepca/` — `pyproject.toml`
  (`pythonpath = ["../../scripts"]`, deps `pytest, pytest-httpserver, …, httpx`).
  `pytest-httpserver` serves canned `/health`, `/provisioners`, `/roots.pem`; the CLI is
  driven via `CliRunner` with `--server-url`. Failure paths covered: status≠ok → exit 2,
  no ACME provisioner → exit 2, empty root → exit 2, connection refused → exit 2.
- **Live (secondary):** `just stepca-check centralized_pki` against a running cluster exits 0.

## Justfile

```
just stepca-check CLUSTER          # check → exit code
just stepca-provisioners CLUSTER   # list provisioners
```

See also [`cli-authelia.md`](cli-authelia.md), [`cli-vaultwarden.md`](cli-vaultwarden.md),
[`cli-tls.md`](cli-tls.md), [`centralized_pki.md`](centralized_pki.md).
