name_prefix = "centralized-netbox"
image       = "24.04"
netbox_port = 8000

# netbox-docker source pin. 3.0.2 ships NetBox v4.1 (v1 plaintext tokens — required for a pinned
# lab token; 4.2+ uses hashed v2/Bearer tokens that can't be set to a known value).
netbox_docker_ref = "3.0.2"

# LAB-ONLY pinned token / creds — deterministic self-registration + verify. Not a secret.
netbox_api_token          = "0123456789abcdef0123456789abcdef01234567"
netbox_superuser_name     = "admin"
netbox_superuser_password = "admin"

# Virtualization cluster the client self-registers into.
cluster_type = "Multipass"
cluster_name = "centralized-netbox"

server = {
  cpus   = 2
  memory = "4G"
  disk   = "20G"
}

client = {
  cpus   = 1
  memory = "1G"
  disk   = "10G"
}
