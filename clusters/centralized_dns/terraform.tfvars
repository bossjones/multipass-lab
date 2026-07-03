# Defaults for the centralized_dns cluster. Secrets here are DEV-ONLY (see DEFAULT_PASSWORDS.md);
# override any of them via TF_VAR_* or a gitignored *.auto.tfvars for a non-throwaway deployment.

name_prefix = "centralized-dns"
image       = "24.04"
