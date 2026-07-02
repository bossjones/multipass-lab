# Defaults for the centralized_pki cluster. Secrets here are DEV-ONLY (see DEFAULT_PASSWORDS.md);
# override any of them via TF_VAR_* or a gitignored *.auto.tfvars for a non-throwaway deployment.

name_prefix = "centralized-pki"
image       = "24.04"
domain      = "lab.theblacktonystark.com"

# Let's Encrypt staging is OFF by default — the lab issues internal certs from step-ca's ACME and
# needs no external secrets. Set enable_letsencrypt_staging = true (plus TF_VAR_godaddy_api_key /
# TF_VAR_godaddy_api_secret) to pull a real LE *staging* wildcard via DNS-01. See specs/centralized_pki.md.
enable_letsencrypt_staging = false
