# Fact sheet: centralized_pki

**One-liner:** This is the lab's internal CA (step-ca) + Traefik fleet edge reverse proxy running Authelia + Vaultwarden.

**VMs:**
| VM role | Count | Sizing | Purpose |
|---|---|---|---|
| `ca` (`centralized-pki-ca`) | 1 | 1 vCPU / 1G / 10G | step-ca `:9000` — root/intermediate CA (generated at first boot, or pinned via `scripts/init_ca.py`) |
| `services` (`centralized-pki-services`) | 1 | 2 vCPU / 4G / 25G | Traefik `:80/:443/:8080` fronting Authelia (SSO forward-auth) + Vaultwarden; also the fleet-wide reverse-proxy edge |

**Existing docs (confirmed to exist on disk):**
- `clusters/centralized_pki/README.md`
- `clusters/centralized_pki/USAGE.md`
- `clusters/centralized_pki/DEFAULT_PASSWORDS.md`

**Specs:**
- `specs/centralized_pki.md` — main design spec (architecture, layout, testing, quickstart, live-validation gotchas, future work)
- `specs/pki-and-dns.md` — combined internal-CA trust + Phase-2 TLS + DNS auto-registration design (covers multiple clusters, pki included as the trust-anchor/Phase-0/1 source)
- `specs/dynamic-traefik.md` — fleet-edge Traefik reverse-proxy design (pki hosts the edge; consumed by `centralized_netbox`, `centralized_dns`, `centralized_logging`)

**web_urls / core dashboards (from outputs.tf):**
`web_urls.core` (always present, human-facing):
- `https://auth.<domain>` — Authelia (forward-auth SSO portal)
- `https://warden.<domain>` — Vaultwarden
- `http://<services-ip>:8080` — Traefik dashboard
- `https://<ca-ip>:9000/health` — step-ca health endpoint

`web_urls.all` additionally folds in every enabled `/metrics` exporter on both VMs (gated per-flag): `node_exporter :9100`, `process-exporter :9256`, `systemd_exporter :9558` — each on both `ca` and `services` IPs when its `enable_*` flag is on (all three default on).

Other notable outputs: `hosts` (role→{name,ipv4} for testinfra SSH), `dns_records` (`auth.`/`warden.`/`traefik.`/`ca.` → IPs, consumed by `just set-dns`), `reverse_proxy_routes` (pki's own `auth`/`warden` routes, published for discoverability — doesn't change routing today), `root_ca_pem` (empty unless a pinned root is configured via `scripts/init_ca.py`), `acme_directory_url`, `enabled_flags`, `docker_tools_enabled`, `shell_hints`.

**Notes for the doc authors:**
- **Missing from CLAUDE.md's "## Clusters" enumeration sentence**, but referenced extensively in later prose: the "Internal-CA trust (opt-in)" paragraph (persisted CA material via `scripts/init_ca.py generate`, `just trust-ca`/`trust-ca-all`/`trust-ca-macos`), the "Internal-CA TLS (Phase 2, opt-in)" paragraph (needs `ca_ip` + `stepca_ca_password` from pki wired into `centralized_monitoring`), and the "Fleet-edge Traefik (opt-in via sync, not a flag)" paragraph (pki's Traefik doubles as the fleet-wide reverse-proxy edge for `centralized_netbox`, `centralized_dns`'s AdGuard UI, and `centralized_logging`'s Coroot). Doc authors should treat pki as a first-class cluster despite the omission.
- **Two VMs, isolated CA by design.** The `ca` VM is deliberately tiny/isolated (no ACME reachback needed) — see spec's "Why direct JWK issuance, not Traefik→step-ca ACME" rationale: ACME requires the CA to connect back to `auth./warden.<domain>`, which resolves nowhere in a DNS-less lab, so certs are issued via a password-protected JWK provisioner with no challenge/reachback, renewed by a 12h host timer.
- **Editing cloud-init needs `just recreate centralized_pki`**, same repo-wide convention (OpenTofu doesn't recreate a `multipass_instance` on rendered-content-only changes).
- **Secrets are dev defaults, all overridable via `TF_VAR_*`** — see `DEFAULT_PASSWORDS.md` (step-ca password doubles as the JWK provisioner password; Authelia user/password/session/storage/jwt secrets; Vaultwarden admin token).
- **Let's Encrypt staging is opt-in** (`enable_letsencrypt_staging`, default off) via GoDaddy DNS-01 — off by default so the cluster stays hermetic with no external secrets; step-ca issues the default cert.
- **This cluster is also the fleet-edge Traefik host** (`specs/dynamic-traefik.md`): its Traefik file provider runs in `directory` mode merging its own static `dynamic.yaml` (auth./warden.) with a hot-pushed `fleet.yaml` (`just traefik-sync`, no VM recreate/restart) built from every participating cluster's `reverse_proxy_routes` output. `centralized_monitoring` is explicitly **excluded** from the fleet edge — it already terminates its own TLS (Phase 2) at `<svc>.<domain>` directly.
- **DNS registration is REST-API-driven, not boot-time**: `dns_records` output + `just set-dns`/`set-dns-all` call `adguard_cli.py rewrite-sync` against the running `centralized_dns` AdGuard hub — no recreate needed when IPs change. For fleet-fronted hosts, `traefik_cli.py dns-rewrites` output is layered on top so those hostnames resolve to pki's edge IP rather than the backend service's own IP.
- **Live-validated gotchas worth surfacing to readers** (from spec's "Live-validation notes"): step-ca password must be passed as `DOCKER_STEPCA_INIT_PASSWORD` (not a mounted file); the cert-issuing `step-cli` container needs `--user 0:0` to read a root-owned `0600` password file; Traefik routing uses the **file** provider (not docker provider — Traefik v3.1's docker provider speaks Docker API v1.24, rejected by Docker ≥28); `package_upgrade: false` avoids pushing the services VM past the multipass launch timeout.
