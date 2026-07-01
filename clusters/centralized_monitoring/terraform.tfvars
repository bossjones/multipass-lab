name_prefix = "centralized-monitoring"
image       = "24.04"

prometheus_scrape_interval = "15s"

server = {
  cpus   = 4
  memory = "8G"
  disk   = "40G"
}

k0s_client = {
  cpus   = 2
  memory = "4G"
  disk   = "30G"
}

# Feature flags — tier posture is MVP + Reach ON, Nice-to-have OFF. The defaults
# in variables.tf already encode this; the blocks below are here for discoverability
# (uncomment / flip to change the footprint). A disabled flag is neither installed
# on the VM nor scraped by Prometheus.

# --- MVP (on) ---------------------------------------------------------------
# enable_otel             = true
# enable_openobserve      = true
# enable_blackbox         = true
# enable_node_exporter    = true
# enable_cadvisor         = true
# enable_process_exporter = true
# enable_netdata          = true

# --- Reach (on) -------------------------------------------------------------
# enable_kube_state_metrics = true
# enable_kubelet_scrape     = true
# enable_heimdall           = true
# enable_heimdall_seed      = true   # auto-seed Heimdall tiles at boot (needs enable_heimdall)
# enable_uptime_kuma        = true
# enable_traefik            = true
# enable_statsd_exporter    = true
# enable_ssh_exporter       = true
# enable_filestat_exporter  = true

# --- Reach but lab-hostile (off by default) ---------------------------------
# enable_nut_exporter      = true   # needs a real UPS / upsd
# enable_nftables_exporter = true   # upstream is a Python tool (no portable binary)

# --- Nice-to-have (off) -----------------------------------------------------
# enable_osquery_exporter = true
# enable_ebpf_exporter    = true   # needs linux-headers
# enable_texporter        = true   # needs linux-headers
# enable_ffmpeg_exporter  = true
# enable_script_exporter  = true
# enable_vector           = true
