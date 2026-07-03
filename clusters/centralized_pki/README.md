# centralized_pki

A two-VM Multipass cluster: a private **step-ca** CA + **Traefik** fronting **Authelia**
(SSO) and **Vaultwarden**, with browser-facing certs auto-issued from step-ca (default) or
Let's Encrypt **staging** (opt-in). Design: [`specs/centralized_pki.md`](../../specs/centralized_pki.md).

```
ca        (centralized-pki-ca)        step-ca :9000
services  (centralized-pki-services)  Traefik :80/:443/:8080 → Authelia + Vaultwarden
```

## Quickstart

```sh
just check centralized_pki       # hermetic: fmt + validate + tofu test (no VMs)
just up centralized_pki          # launch both VMs (waits for cloud-init)
just verify centralized_pki      # live testinfra over SSH
just verify-pki centralized_pki  # host-side step-ca/Authelia/Vaultwarden + TLS checks
just open centralized_pki        # open dashboards in the browser
just destroy centralized_pki
```

## Certs

- **Default (no secrets):** Traefik serves a cert step-ca issues directly via its JWK
  provisioner (SANs `auth.<domain>` + `warden.<domain>`); a 12h timer renews it. `test_certs`
  proves the served leaf chains to the step-ca root.
- **Opt-in LE staging:** set `enable_letsencrypt_staging = true` + `TF_VAR_godaddy_api_key`
  / `TF_VAR_godaddy_api_secret`, then `just recreate centralized_pki`. Traefik pulls an LE
  **staging** wildcard via DNS-01 (GoDaddy). See [`specs/centralized_pki.md`](../../specs/centralized_pki.md).

## Secrets

All service secrets have **dev defaults** so `just up` is turnkey — see
[`DEFAULT_PASSWORDS.md`](DEFAULT_PASSWORDS.md). Override any via `TF_VAR_*`.

## Verify a single thing

```sh
just stepca-check centralized_pki
just authelia-check centralized_pki
just vaultwarden-check centralized_pki
cd tests/stepca && uv run pytest -q          # a hermetic CLI suite
tofu -chdir=clusters/centralized_pki test -test-directory=tests/tofu   # hermetic render
```

See [`USAGE.md`](USAGE.md) for the full command reference.
