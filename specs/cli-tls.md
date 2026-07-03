# Spec: TLS chain verification CLI (`tls-cli`)

## Context

`clusters/centralized_pki`'s whole point is trusted internal TLS: Traefik on the `services`
VM serves a cert issued by step-ca (default mode) or Let's Encrypt **staging** (opt-in). The
load-bearing assertion — *"is the cert a browser lands on actually issued by the CA we
expect?"* — is cross-service and doesn't belong in any one app's CLI. This spec designs
`tls_cli.py`, the Python equivalent of the wildcard-cert doc's
`openssl s_client | openssl x509` check.

### Library choice

Chain verification uses the **stdlib `ssl`** (a real handshake with `cafile=<root>` proves
the chain); field parsing (CN/issuer/SANs/validity) uses
[`cryptography`](https://cryptography.io/). No SDK, no httpx.

## Objective

Ship `tls_cli.py` with `inspect` (dump the served leaf) and a flag-aware `check`, wired via
`just tls-check`, covered by a hermetic pytest suite that stands up a real in-process TLS
server with fixture certs (no VM).

## Architecture

```
  operator laptop                              centralized-pki-services VM (Traefik :443)
  ┌───────────────────────────┐  TLS handshake ┌─────────────────────────────────────────┐
  │ tls_cli.py (ssl+cryptography)│ ────────────► │ Traefik serves the leaf for <SNI>        │
  │  verify_chains_to(root)      │ ◄──────────── │  (step-ca cert, or LE-staging wildcard)  │
  └───────────────────────────┘                └─────────────────────────────────────────┘
```

Because lab hostnames don't resolve on the laptop, `--sni auth.<domain>` connects by the
services IP while presenting the hostname for SNI + cert matching (`check_hostname` is off,
so IP connections are fine). The mode is derived from the cluster's `enabled_flags`
(`enable_letsencrypt_staging`) unless overridden with `--staging`/`--internal`.

## Command surface

Global options: `--cluster`, `--json`, `--timeout`.

| Subcommand | Purpose |
|---|---|
| `inspect HOST [--port] [--sni]` | dump the served leaf: subject CN, issuer CN, SANs, validity |
| `check HOST [--port] [--sni] [--ca-cert] [--staging/--internal]` | assert the expected issuer/root & exit nonzero |

## `check` semantics (exit 0 pass / 2 fail)

- **internal mode** (default): the served leaf **chains to step-ca's root**
  (`verify_chains_to`, root from `--ca-cert` or fetched from the cluster's `/roots.pem`).
- **staging mode** (`enable_letsencrypt_staging` on): the leaf's **issuer CN contains
  `STAGING`** (Let's Encrypt staging).

Any `fail` → exit 2. Unreachable host / missing root → `fail` + exit 2.

## Testing

- **Hermetic (primary, TDD):** `clusters/centralized_pki/tests/tls/` — `conftest.py` builds a
  self-signed root + a leaf signed by it (with SKI/AKI/KeyUsage so OpenSSL's strict verifier
  accepts it), plus a leaf whose issuer CN mimics `(STAGING) Pretend Pear X1`, and serves each
  from a threaded `ssl` TLS server on a random port. Tests: correct root → exit 0, wrong root
  → exit 2, staging issuer with `--staging` → exit 0, non-staging issuer with `--staging` →
  exit 2, `inspect` reports issuer/subject/SANs.
- **Live (secondary):** `just tls-check centralized_pki <services-ip> --sni warden.<domain>`
  exits 0 (also driven by `just verify-pki`).

## Justfile

```
just tls-check CLUSTER HOST [--sni h.<domain>] [--ca-cert root.pem]   # check → exit code
just verify-pki CLUSTER                                                # all service checks + tls-check auth./warden.
```

See also [`cli-stepca.md`](cli-stepca.md), [`cli-authelia.md`](cli-authelia.md),
[`cli-vaultwarden.md`](cli-vaultwarden.md), [`centralized_pki.md`](centralized_pki.md).
