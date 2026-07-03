name_prefix = "centralized-logging"
image       = "24.04"
syslog_port = 514

# $HOST foldering on central: keep | dns | ip (see variables.tf).
hostname_source = "keep"

central = {
  cpus   = 2
  memory = "2G"
  disk   = "40G"
}

k0s_client = {
  cpus   = 2
  memory = "2G"
  disk   = "20G"
}
# NOTE: when enable_coroot = true the k0s VM is auto-bumped to 4 vCPU / 8G / 50G (Coroot bundles
# Prometheus + ClickHouse) — see local.k0s_size in main.tf. No manual edit here is needed.

docker_client = {
  cpus   = 2
  memory = "4G"
  disk   = "25G"
}

# --- Coroot (self-hosted eBPF observability) — opt-in, see specs/coroot.md -----------------
# Uncomment to deploy Coroot onto the k0s node and expose its UI via ingress. Both default off.
enable_coroot   = true
enable_ingress  = true
coroot_host     = "coroot.local" # ingress Host header for the UI (or add to /etc/hosts)
coroot_nodeport = 30080          # browser-friendly UI URL: http://<k0s_ip>:30080
