# Default credentials (DEV ONLY)

Every secret below has a **dev default** so `just up centralized_pki` works with no setup.
They are rendered only into `.rendered/` (gitignored) and mounted read-only in containers —
**never** commit real secrets. Override any value via `TF_VAR_<name>` or a gitignored
`*.auto.tfvars`. These are throwaway lab VMs.

| Thing | Default | Override |
|---|---|---|
| step-ca key password (also the JWK provisioner password) | `changeit-dev-pki-only` | `TF_VAR_stepca_ca_password` |
| Authelia user | `admin` | `TF_VAR_authelia_user` |
| Authelia password | `password` (argon2id hash of it is the default) | `TF_VAR_authelia_password_hash` |
| Authelia session / storage / jwt secrets | dev placeholders | `TF_VAR_authelia_session_secret` / `_storage_key` / `_jwt_secret` |
| Vaultwarden `/admin` token | `dev-vaultwarden-admin-token-change-me` | `TF_VAR_vaultwarden_admin_token` (empty disables `/admin`) |
| GoDaddy API key/secret (LE staging only) | empty | `TF_VAR_godaddy_api_key` / `TF_VAR_godaddy_api_secret` |

## Notes

- The Authelia default password hash is Authelia's documented example argon2id digest of the
  plaintext **`password`**. Generate your own with
  `docker run --rm authelia/authelia:4.38 authelia crypto hash generate argon2 --password '<pw>'`
  and pass it as `TF_VAR_authelia_password_hash`.
- The step-ca password protects the CA's root/intermediate keys **and** authenticates the JWK
  provisioner the services VM uses to issue Traefik's cert. Change it for anything non-throwaway.
- Vaultwarden allows no signups by default (`SIGNUPS_ALLOWED=false`); create users via `/admin`.
