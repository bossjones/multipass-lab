# centralized_dns — default credentials (DEV / THROWAWAY)

Every secret below is a **development default** for the throwaway lab VM. They are exposed via
`tofu output` on purpose (like the NetBox lab token). **Do NOT reuse these on a real deployment.**

| What | Default | Override |
|---|---|---|
| AdGuard Home admin user | `admin` | `TF_VAR_adguard_user` |
| AdGuard Home admin password | `test1234` | `TF_VAR_adguard_password` |
| AdGuard Home password hash | bcrypt(`test1234`) | `TF_VAR_adguard_password_hash` |
| VRRP unicast auth password (HA only) | `labvrrp1` | `TF_VAR_vrrp_auth_pass` (keepalived truncates simple-text auth to 8 chars — keep any override <= 8 chars) |

The seeded `AdGuardHome.yaml` needs the **bcrypt hash**; the exporter and the CLIs need the
**plaintext**. They must agree, so when changing the password regenerate the hash together:

```sh
# generate a new bcrypt hash for a chosen plaintext
/opt/AdGuardHome/AdGuardHome --hash-password        # (on the VM), or:
htpasswd -B -n -b admin 'my-new-password'           # take the part after the first ':'
```

Then set both `TF_VAR_adguard_password` and `TF_VAR_adguard_password_hash` and
`just recreate centralized_dns`.

Retrieve the live credentials:

```sh
tofu -chdir=clusters/centralized_dns output -json adguard_credentials
```
