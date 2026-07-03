name_prefix = "centralized-netbox"
image       = "24.04"
netbox_port = 8000

# netbox-docker source pin. 3.0.2 ships NetBox v4.1 (v1 plaintext tokens — required for a pinned
# lab token). Pinnable v1 tokens survive through 4.4.x; NetBox 4.5+ uses hashed v2/Bearer tokens
# that can't be set to a known value (see specs/netbox-discovery.md).
netbox_docker_ref = "3.0.2"

# LAB-ONLY pinned token / creds — deterministic self-registration + verify. Not a secret.
netbox_api_token          = "0123456789abcdef0123456789abcdef01234567"
netbox_superuser_name     = "admin"
netbox_superuser_password = "admin"

# Virtualization cluster the client self-registers into.
cluster_type = "Multipass"
cluster_name = "centralized-netbox"

# Discovery (opt-in NetBox Labs Diode + orb-agent). OFF by default — the cluster stays exactly as
# it is today (NetBox 4.1, pinned token, self-registration). Flip to true + `just recreate
# centralized_netbox` to bump NetBox to 4.4.x, build the diode-netbox-plugin image, deploy the
# Diode server stack, and add a third VM that scans the Multipass /24. See specs/netbox-discovery.md.
enable_discovery = false

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
