# Internal CA — fleet-wide trust + internal-CA TLS

Design mirrors `specs/cross-cluster.md` and `specs/centralized_pki.md`. This spec makes the lab's
internal step-ca the trusted CA on **every** machine (all cluster VMs + the macOS host) and, in a
later phase, moves services off plain HTTP onto internal-CA-issued TLS when they aren't on Let's
Encrypt.

## Context

Today `clusters/centralized_pki` runs **step-ca** and is the *only* cluster doing TLS. It issues
Traefik leaves for `auth.<domain>` / `warden.<domain>` and serves its root at
`https://ca.<domain>:9000/roots.pem`. Two problems block "use our internal CA everywhere":

1. **Nobody trusts the root.** Only the PKI *services* VM installs it
   (`/usr/local/share/ca-certificates/step-ca-root.crt` + `update-ca-certificates`, in
   `clusters/centralized_pki/cloud-init/services.yaml.tftpl:124-128`). Every other VM, and the
   **macOS host** (Chrome/Firefox/Safari), sees an untrusted cert. There is zero macOS trust tooling.
2. **The root is ephemeral.** step-ca generates root+intermediate *at first boot* inside the
   `step_data` Docker volume, so the root isn't known at `tofu apply` time, isn't a tofu output,
   and **regenerates on every `just recreate centralized_pki`** — breaking all distributed trust
   each rebuild.

Goal: when a service isn't on Let's Encrypt, it uses our internal CA, and every machine in the lab
(all cluster VMs + the macOS laptop) trusts that CA so browsers/CLIs show a valid, green-lock cert.

## Decisions

- **Scope:** Phase it — Phase 1 = fleet-wide + macOS *trust*; Phase 2 = *server certs* per cluster.
- **Root stability:** **Persist** the root so it survives PKI rebuilds and macOS trust stays valid.
- **macOS:** Include a macOS trust helper (System keychain **and** Firefox NSS via `certutil`).
- **Delivery:** Both — static first-boot injection *plus* a hot-push `just` recipe for running VMs.

## Key design insight

**Persisting the root collapses the whole delivery problem.** If the root cert+key are generated
once and pinned as sensitive vars (in `.env`/tfvars), the **root cert PEM is known at apply time**.
Then `internal_ca_cert` is just a static string — every cluster (even a plain `just up <cluster>`,
even the DNS hub) can trust it at first boot via `write_files`, with **no hub ordering, no runtime
fetch, no `/roots.pem` TOFU**. This is strictly simpler than the `dns_server` runtime-IP pattern.

## Phase 0 — Persist the step-ca root (foundation)

Generate root+intermediate **once**, offline, and make step-ca adopt them instead of self-initializing.

- New host script `clusters/centralized_pki/scripts/init_ca.py` (uv single-file, typer+rich, wraps
  `step certificate create`): produces `root_ca.crt`, `intermediate_ca.crt`, `intermediate_ca_key`
  (password-encrypted). Prints them for capture into `.env` (gitignored, hook-blocked from reads).
- New **sensitive** vars in `centralized_pki/variables.tf`: `root_ca_cert`, `intermediate_ca_cert`,
  `intermediate_ca_key`, reusing the existing `stepca_ca_password` for the key. Empty default →
  fall back to today's `DOCKER_STEPCA_INIT_*` self-init (backward compatible).
- `cloud-init/ca.yaml.tftpl` + `cloud-init/step-ca/compose.yaml.tftpl`: when the vars are set,
  `write_files` the three files into `/home/step/certs` + `/home/step/secrets` before `docker
  compose up`; step-ca skips init when material exists. Drop the `SELF_IP`-only DNS-name init in
  favor of the pinned material (SANs on the `:9000` leaf still include `<SELF_IP>`).
- New output `root_ca_pem` (= `var.root_ca_cert`) in `centralized_pki/outputs.tf` — now static, so
  it's the source everything else reads.

## Phase 1 — Fleet-wide + macOS trust

### 1a. Shared cloud-init snippet + per-cluster wiring (mirror `dns_server` exactly)

- Add `variable "internal_ca_cert"` (string, default `""`) to **all six** clusters' `variables.tf`
  (same set that already accepts `dns_server`: `centralized_{dns,logging,monitoring,netbox,pki,unifi}`).
- In each `main.tf`: `local.trust_ca = var.internal_ca_cert != ""`, and thread `internal_ca_cert`
  into **every** VM `templatefile(...)` call, next to `dns_server`/`dns_resolved_conf`.
- In each VM `*.tftpl`, add a gated block (copy the idiom already in `services.yaml.tftpl:127-128`):
  ```
  %{ if internal_ca_cert != "" ~}
    - path: /usr/local/share/ca-certificates/internal-root-ca.crt
      permissions: '0644'
      content: |
        ${indent(6, internal_ca_cert)}
  %{ endif ~}
  ```
  and in `runcmd` (early, before any internal-HTTPS `curl`): `%{ if internal_ca_cert != "" ~}
  - update-ca-certificates%{ endif ~}`.
- Because the PEM is a static var (Phase 0), a plain `just up <cluster>` already trusts the CA.

### 1b. `up-connected` wiring

- In `Justfile` `up-connected`, read the root once: `ca_pem="$(tofu -chdir=.../centralized_pki
  output -raw root_ca_pem)"`, and add `internal_ca_cert: $ca_pem` to the `jq -n` object written into
  every cluster's `.cross-cluster.auto.tfvars.json` (including the DNS/logging/monitoring hub blocks).
  No ordering change needed since the value is static.

### 1c. Hot-push repair recipe (no recreate)

- New `just trust-ca <cluster>` recipe: for each VM in the cluster's `hosts` output, scp the root
  PEM to `/usr/local/share/ca-certificates/internal-root-ca.crt` over SSH and run
  `update-ca-certificates`. Mirrors the existing Prometheus/DNS hot-push recipes in `up-connected`.
  Add `just trust-ca-all` (glob over clusters).

### 1d. macOS trust helper

- New `clusters/centralized_pki/scripts/macos_trust_cli.py` (uv single-file, typer+rich), extending
  the existing `tls_cli.py`/`_pki_common.py` root-resolution:
  - `install` — write root to a temp PEM, then:
    - **System keychain** (Chrome/Safari): `security add-trusted-cert -d -r trustRoot -k
      /Library/Keychains/System.keychain <root.pem>` (prompts for sudo — surfaced, not run silently).
    - **Firefox** (separate NSS store): `certutil -A -n "lab internal CA" -t "C,," -d
      sql:<each ~/Library/Application Support/Firefox/Profiles/*>` (needs `nss` via brew; detect+warn).
  - `remove` — reverse both. `check` — verify a served leaf validates against the OS trust (exit 0/2).
- Because these mutate the host keychain, the recipe **prints the commands and asks for
  confirmation**; it is not part of `up-connected`.

## Phase 2 — Services serve HTTPS with internal-CA certs

Reuse the PKI cluster's proven "get a leaf" recipe (`issue-cert.sh` + JWK `admin` provisioner +
12h renew timer, `services.yaml.tftpl:102-172`) as a shared, parameterized building block.

- Promote the leaf-issuance logic to `clusters/_shared/cloud-init/issue-cert.sh.tftpl` (params:
  `ca_url`, `jwk_provisioner`, SAN list, cert paths) so each cluster renders its own SANs.
- Per target cluster, add a TLS-terminating reverse proxy in front of existing plain-HTTP services
  and point it at the issued leaf. Priority order (highest value / already has a proxy first):
  1. **centralized_monitoring** — already has an `enable_traefik` flag; front Grafana/Prometheus/
     OpenObserve/Uptime-Kuma. SANs like `grafana.<domain>`, `prometheus.<domain>`.
  2. **centralized_logging** — already runs Traefik `:80`; add `:443` + leaf for Heimdall/Grafana.
  3. **centralized_netbox** — NetBox UI/API + the Diode nginx ingress (gRPC benefits from TLS).
  4. **centralized_dns** — AdGuard Home UI (single service; lower priority).
  5. **centralized_unifi** — ships its own self-signed; lowest priority.
- Each gets a `use_internal_tls` flag (default off) so `just up` stays turnkey. `web_urls` outputs
  switch `http://IP:port` → `https://<svc>.<domain>` when the flag is on.
- **DNS dependency:** browser HTTPS by hostname needs `*.<domain>` resolving to the service IP —
  wire these `A` records into the `centralized_dns` AdGuard config (rewrite rules) as part of each
  cluster's Phase 2 cutover.

## Tests

- **Hermetic (`tests/tofu/*.tftest.hcl`, `just check`):** for each cluster, assert that with
  `internal_ca_cert` set the rendered cloud-init contains `/usr/local/share/ca-certificates/
  internal-root-ca.crt` + `update-ca-certificates`, and absent when empty (mirror the existing
  DNS/log/otel assertions in `cross_cluster.tftest.hcl`). PKI: assert pinned-root path renders the
  three files and skips self-init; `root_ca_pem` output non-empty.
- **Hermetic CLI:** `tests/macos_trust/` with `CliRunner` + a fake `security`/`certutil` on PATH
  (no real keychain writes), like the existing `tests/tls/` suite.

## Verification (end-to-end)

1. `just check centralized_pki` and `just check <each cluster>` — hermetic pass.
2. Phase 0: `just recreate centralized_pki`; confirm the *pinned* root is served:
   `curl -k https://<ca_ip>:9000/roots.pem` equals `tofu output -raw root_ca_pem`; recreate again and
   confirm the root is unchanged (persistence works).
3. Phase 1: `just up-connected`; SSH to a VM in each cluster and confirm
   `ls /usr/local/share/ca-certificates/internal-root-ca.crt` and that
   `openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt <a served leaf>` returns OK. Confirm
   `just trust-ca <cluster>` repairs a VM without recreate.
4. macOS: run `macos_trust_cli.py install`; open `https://auth.<domain>` in Chrome and Firefox →
   green lock, no warning; `macos_trust_cli.py check` exits 0.
5. Phase 2 (per cluster as cut over): `just verify-api <cluster>` still green over HTTPS;
   `tls_cli.py check` confirms the served leaf chains to the internal root.
