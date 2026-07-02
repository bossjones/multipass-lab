# Spec: `centralized_pki` cluster

## Context

A **PKI + identity** cluster to prototype trusted internal TLS before promoting it to
Proxmox/k0s. It stands up a private CA and puts SSO + a vault behind a TLS-terminating
reverse proxy, all via Docker Compose on Multipass VMs — mirroring the two-VM,
two-layer-test conventions of `centralized_logging` / `centralized_monitoring`.

- **step-ca** (smallstep) — a private internal CA with an ACME provisioner (`acme`) and a
  password-protected JWK provisioner (`admin`). Auto-issues/rotates internal certs; no root
  CA to distribute to laptops (only the handful of internal services trust it).
- **Traefik** — terminates TLS in front of **Authelia** (forward-auth SSO) and
  **Vaultwarden** (Bitwarden-compatible vault).
- **Let's Encrypt staging** — an **opt-in** flag (`enable_letsencrypt_staging`, default off).
  Off: Traefik serves a cert step-ca issues directly (hermetic, no external secrets). On:
  Traefik pulls an LE **staging** wildcard via DNS-01 (GoDaddy). Flip to LE production once
  validated (<https://letsencrypt.org/docs/staging-environment/>).

Design decisions (settled up front): Docker Compose on VMs (not k0s/cert-manager) · Authelia
(not Authentik) · LE staging opt-in (not required) · two VMs with an isolated CA.

## Objective

`just up centralized_pki` launches two VMs:

| Role (VM) | Runs | Notes |
|---|---|---|
| `ca` (`centralized-pki-ca`) | step-ca `:9000` | root/intermediate generated at first boot |
| `services` (`centralized-pki-services`) | Traefik `:80/:443/:8080`, Authelia, Vaultwarden | issues its Traefik cert from step-ca |

## Architecture

```
                 ┌───────────── centralized-pki-ca ─────────────┐
                 │ step-ca (Docker) :9000                        │
                 │  /health /roots.pem /provisioners  (ACME+JWK) │
                 └───────▲───────────────────────────┬───────────┘
  created FIRST          │ JWK issue (password auth)  │ /roots.pem (TOFU bootstrap)
  (its ipv4 is the       │ no ACME challenge/reachback│
  render-ordering edge)  │                            ▼
   ┌──────────────── centralized-pki-services ─────────────────────────┐
   │ issue-cert.sh -> step ca certificate (SANs auth./vault.<domain>)   │
   │ Traefik :443 serves it as defaultCertificate (file provider watch) │
   │   Authelia :9091 (forwardAuth)   Vaultwarden :80 (/admin gated)    │
   └────────────────────────────────────────────────────────────────────┘
```

**Why direct JWK issuance, not Traefik→step-ca ACME.** ACME (tls-alpn-01/http-01) requires
the CA to connect *back* to `auth./vault.<domain>`, which resolves nowhere in a DNS-less lab,
and the CA/services VMs have a mutual-IP dependency that can't be met in one `tofu apply`.
The JWK provisioner authenticates with the CA password and issues any SAN with **no
challenge/reachback** — the correct DNS-free primitive. A 12-hour host timer re-issues and
Traefik's file-provider `watch` reloads it. (The opt-in LE-staging path keeps ACME because
**DNS-01** needs no inbound reachback.)

### Conventions (shared with the other clusters)

- **Runtime IP injection.** `local_file.services_ci` interpolates `multipass_instance.ca.ipv4`,
  forcing the `ca` VM to exist (and its DHCP IP to be known) before `services` renders — the
  same edge `centralized_logging` creates between `central` and its clients.
- **step-ca root trust.** The root is generated inside the `ca` VM at boot, so its fingerprint
  isn't known at plan/apply time. The services VM `curl -fsSk .../roots.pem` (step-ca's
  documented TOFU bootstrap — the payload is the self-authenticating root), trusts it, then
  issues the Traefik leaf. No two-phase apply, single `tofu apply`.
- **Providers.** `larstobi/multipass ~> 1.4` + `hashicorp/local ~> 2.4`, `required_version >= 1.7`.
  `cloudinit_file` is a file path (`.rendered/<role>.yaml`).
- **Time.** UTC + `systemd-timesyncd` on both VMs, re-enforced in `runcmd` (see `specs/ntp.md`).

## Layout

```
clusters/centralized_pki/
├── versions.tf providers.tf variables.tf main.tf outputs.tf terraform.tfvars
├── README.md USAGE.md DEFAULT_PASSWORDS.md
├── cloud-init/
│   ├── ca.yaml.tftpl services.yaml.tftpl
│   ├── step-ca/compose.yaml.tftpl
│   ├── docker/compose.yaml.tftpl
│   ├── traefik/{traefik.yaml.tftpl,dynamic.yaml.tftpl}
│   └── authelia/{configuration.yaml.tftpl,users_database.yaml.tftpl}
├── scripts/{_pki_common.py,stepca_cli.py,authelia_cli.py,vaultwarden_cli.py,tls_cli.py}
└── tests/
    ├── tofu/sizing_and_render.tftest.hcl                 # hermetic
    ├── testinfra/{conftest.py,test_ca.py,test_services.py,test_certs.py}  # live
    └── {pki_common,stepca,authelia,vaultwarden,tls}/     # hermetic CLI suites
```

## Testing

- **Layer 0/1 hermetic** (`just check centralized_pki`) — `tests/tofu/*.tftest.hcl` with
  `mock_provider "multipass" {}` + `command = plan`: VM sizing/names, step-ca + ACME render on
  `ca`, Traefik/Authelia/Vaultwarden + direct issuance + `defaultCertificate` on `services`,
  LE-staging block present only with the flag, NTP/UTC, `yamldecode` validity, `web_urls`.
- **Hermetic CLI suites** — `tests/{pki_common,stepca,authelia,vaultwarden,tls}/`:
  `pytest-httpserver` + `CliRunner` (and a real `ssl` fixture server for `tls`), no VM.
- **Layer 2 live** (`just verify centralized_pki`) — testinfra over SSH: step-ca healthy +
  provisioners, Traefik/Authelia/Vaultwarden up + reachable through Traefik, and `test_certs`
  proves the served leaf **chains to the step-ca root**.
- **Live API/TLS** (`just verify-pki centralized_pki`) — the host-side `*_cli.py` checks +
  `tls-check` for `auth.`/`vault.<domain>`.

## Quickstart

```sh
just check centralized_pki       # hermetic (no VMs)
just up centralized_pki          # launch both VMs
just verify centralized_pki      # live testinfra
just verify-pki centralized_pki  # host-side step-ca/Authelia/Vaultwarden + TLS checks
just open centralized_pki        # open Authelia/Vaultwarden/Traefik/step-ca in the browser
just ssh centralized_pki ca      # shell onto the CA VM
just destroy centralized_pki
```

Secrets are DEV defaults (see `DEFAULT_PASSWORDS.md`); override via `TF_VAR_*`.

## Applying cloud-init changes

Editing a `.tftpl` requires `just recreate centralized_pki` — a plain `just up` reuses the old
VM (OpenTofu doesn't recreate a `multipass_instance` when only the rendered cloud-init changes),
so `just verify` would run against stale cloud-init.

## Let's Encrypt staging (opt-in)

```sh
export TF_VAR_godaddy_api_key=... TF_VAR_godaddy_api_secret=...
just recreate centralized_pki   # with -var enable_letsencrypt_staging=true (or set in terraform.tfvars)
just tls-check centralized_pki <services-ip> --sni vault.<domain>   # asserts issuer contains STAGING
```

Promote to **production** by swapping the Traefik `caServer` to
`https://acme-v02.api.letsencrypt.org/directory` once staging validates end-to-end. GoDaddy
DNS-01 is slow/flaky — the config already sets long propagation timeouts.

## Live-validation notes (first `up`)

The hermetic layers (tofu render + all CLI unit suites) are fully green offline. The following
are pinned to plausible current versions but should be confirmed on the first live `just up`
(a lab, easy to bump): the `smallstep/step-ca`, `smallstep/step-cli`, `traefik`,
`authelia/authelia`, and `vaultwarden/server` image tags; that the docker image's initial JWK
provisioner is named `admin` (`DOCKER_STEPCA_INIT_PROVISIONER_NAME`); and the `step ca
certificate` flags. `just verify` + `just verify-pki` are the gates.

## Future work

- Auto-recreate on cloud-init change (shared with the other clusters).
- Authentik variant; a k0s + cert-manager + GoDaddy-webhook variant (the wildcard-cert doc's
  Kubernetes path).
- Strict-trust hardening: pin the step-ca root fingerprint (`step ca bootstrap --fingerprint`)
  via a two-phase apply instead of the `-k` TOFU fetch.
