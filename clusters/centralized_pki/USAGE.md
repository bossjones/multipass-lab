# centralized_pki — usage

All recipes are folder-name driven from the repo root. `CLUSTER` = `centralized_pki`.

## Lifecycle

```sh
just check centralized_pki       # hermetic: tofu fmt + validate + test (no VMs)
just up centralized_pki          # tofu apply -> launch ca + services (waits for cloud-init)
just recreate centralized_pki    # destroy (incl. orphan cleanup) then up — USE THIS after editing cloud-init
just destroy centralized_pki     # tofu destroy + prune orphaned VMs
just prune centralized_pki       # delete VMs tofu no longer tracks (recover a failed up)
just status                      # multipass list
just ssh centralized_pki ca      # shell onto the CA VM (roles: ca | services)
just open centralized_pki [--full]
```

## Verification (two layers)

```sh
# Hermetic (no VMs)
just check centralized_pki
cd clusters/centralized_pki/tests/pki_common   && uv run pytest -q
cd clusters/centralized_pki/tests/stepca       && uv run pytest -q
cd clusters/centralized_pki/tests/tls          && uv run pytest -q
cd clusters/centralized_pki/tests/authelia     && uv run pytest -q
cd clusters/centralized_pki/tests/vaultwarden  && uv run pytest -q

# Live (VMs must be up)
just verify centralized_pki       # testinfra over SSH (test_ca / test_services / test_certs)
just verify-pki centralized_pki   # host-side step-ca/Authelia/Vaultwarden checks + tls-check
```

## Host-side CLIs (introspection + check)

```sh
just stepca-check centralized_pki
just stepca-provisioners centralized_pki
just authelia-check centralized_pki
just vaultwarden-check centralized_pki
just tls-check centralized_pki <services-ip> --sni vault.<domain>

# Or run a CLI directly for other subcommands:
uv run clusters/centralized_pki/scripts/stepca_cli.py --cluster centralized_pki roots
uv run clusters/centralized_pki/scripts/tls_cli.py    --cluster centralized_pki inspect <services-ip> --sni auth.<domain>
```

Each CLI resolves the VM IP from `tofu output` (VMs must be up) or takes `--server-url`.
TLS verification defaults **off** for the service CLIs (Traefik/step-ca serve self-signed /
staging certs); `tls_cli` does the real chain/issuer assertion.

## Browsing the services

`just open centralized_pki` opens Authelia (`https://auth.<domain>`), Vaultwarden
(`https://vault.<domain>`), the Traefik dashboard (`http://<services-ip>:8080`), and step-ca
health. For the `auth.`/`vault.` hostnames to resolve on your machine, add them to
`/etc/hosts` pointing at the services VM IP (or an AdGuard/DNS rewrite) — the lab itself
issues certs without needing public DNS.

## Let's Encrypt staging (opt-in)

```sh
export TF_VAR_godaddy_api_key=... TF_VAR_godaddy_api_secret=...
# set enable_letsencrypt_staging = true in terraform.tfvars (or -var on the apply)
just recreate centralized_pki
just tls-check centralized_pki <services-ip> --sni vault.<domain>   # issuer should contain STAGING
```
