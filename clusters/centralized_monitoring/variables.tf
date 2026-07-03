variable "name_prefix" {
  description = "Prefix for Multipass instance names. Must use hyphens (underscores are invalid in Multipass names)."
  type        = string
  default     = "centralized-monitoring"
}

variable "image" {
  description = "Ubuntu image alias/version passed to multipass (e.g. \"24.04\")."
  type        = string
  default     = "24.04"
}

variable "ssh_pubkey_path" {
  description = "Path to the SSH public key injected into the ubuntu user (used by the testinfra verify loop)."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_pubkey" {
  description = "Inline SSH public key. Overrides ssh_pubkey_path when non-empty (used by hermetic tests)."
  type        = string
  default     = ""
}

variable "server" {
  description = "Resource sizing for the observability server VM."
  type = object({
    cpus   = number
    memory = string
    disk   = string
  })
  default = {
    cpus   = 4
    memory = "8G"
    disk   = "40G"
  }
}

variable "k0s_client" {
  description = "Resource sizing for the monitored single-node k0s VM."
  type = object({
    cpus   = number
    memory = string
    disk   = string
  })
  default = {
    cpus   = 2
    memory = "4G"
    disk   = "30G"
  }
}

variable "prometheus_scrape_interval" {
  description = "Global scrape interval rendered into prometheus.yml."
  type        = string
  default     = "15s"
}

variable "grafana_admin_password" {
  description = "Grafana admin user password (provisioned via compose env)."
  type        = string
  default     = "admin"
  sensitive   = true
}

# --- Feature flags ----------------------------------------------------------
# Every exporter / optional integration is an individual enable_* bool. The flag
# governs BOTH the cloud-init install/compose block AND the matching prometheus.yml
# scrape job (both rendered inside %{ if enable_x ~}…%{ endif ~} conditionals).
# Tier posture: MVP + Reach default true; Nice-to-have default false.

# --- MVP (default on) -------------------------------------------------------

variable "enable_otel" {
  description = "OTel Collector service (OTLP gateway -> Prometheus + OpenObserve)."
  type        = bool
  default     = true
}

variable "enable_openobserve" {
  description = "OpenObserve service + Grafana datasource (OTLP traces/metrics/logs store)."
  type        = bool
  default     = true
}

variable "enable_k0s_log_shipping" {
  description = "otelcol-contrib log-shipping agent on the k0s VM (host + pod logs -> server OpenObserve). Endpoint injected post-apply. Requires enable_openobserve."
  type        = bool
  default     = true
}

variable "enable_blackbox" {
  description = "blackbox_exporter service + blackbox probe job."
  type        = bool
  default     = true
}

variable "enable_node_exporter" {
  description = "node_exporter (--collector.systemd) on both VMs + node job."
  type        = bool
  default     = true
}

variable "enable_cadvisor" {
  description = "cAdvisor container metrics on both VMs + cadvisor job."
  type        = bool
  default     = true
}

variable "enable_process_exporter" {
  description = "process-exporter on the client + process job."
  type        = bool
  default     = true
}

variable "enable_systemd_exporter" {
  description = "systemd_exporter (:9558) on the client + systemd job — per-unit health/resource metrics."
  type        = bool
  default     = true
}

variable "enable_netdata" {
  description = "netdata real-time agent on the client + netdata job."
  type        = bool
  default     = true
}

# --- Reach (default on) -----------------------------------------------------

variable "enable_kube_state_metrics" {
  description = "kube-state-metrics in the k0s cluster + kube-state-metrics job."
  type        = bool
  default     = true
}

variable "enable_kubelet_scrape" {
  description = "kubelet/cAdvisor k8s scrape job against the k0s node."
  type        = bool
  default     = true
}

variable "enable_heimdall" {
  description = "Heimdall homepage / link dashboard service."
  type        = bool
  default     = true
}

variable "enable_heimdall_seed" {
  description = "Auto-seed Heimdall tiles at boot via cloud-init (requires enable_heimdall)."
  type        = bool
  default     = true
}

variable "enable_uptime_kuma" {
  description = "Uptime Kuma human status page service."
  type        = bool
  default     = true
}

variable "enable_traefik" {
  description = "Traefik ingress fronting the stack + traefik job."
  type        = bool
  default     = true
}

# nut_exporter & nftables_exporter are Reach-tier but LAB-HOSTILE, so they default OFF:
# nut_exporter needs a running upsd/UPS (absent in a VM), and nftables_exporter ships only as
# a Python tool (no portable binary release). Flip them on if your target host supports them.
variable "enable_nut_exporter" {
  description = "nut_exporter (UPS / Network UPS Tools) on the client + nut job. Off: needs a real UPS/upsd."
  type        = bool
  default     = false
}

variable "enable_nftables_exporter" {
  description = "nftables_exporter (firewall rule counters) on the client + nftables job. Off: no portable binary release."
  type        = bool
  default     = false
}

variable "enable_statsd_exporter" {
  description = "statsd_exporter (StatsD -> Prometheus bridge) on the server + statsd job."
  type        = bool
  default     = true
}

variable "enable_ssh_exporter" {
  description = "ssh_exporter (SSH endpoint probes) on the server + ssh job."
  type        = bool
  default     = true
}

variable "enable_filestat_exporter" {
  description = "filestat_exporter (file size/mtime/stat) on the client + filestat job."
  type        = bool
  default     = true
}

# --- Nice-to-have (default off) ---------------------------------------------

variable "enable_osquery_exporter" {
  description = "osquery_exporter (osquery results -> metrics) on the client + osquery job."
  type        = bool
  default     = false
}

variable "enable_ebpf_exporter" {
  description = "ebpf_exporter (custom eBPF metrics, needs linux-headers) on the client + ebpf job."
  type        = bool
  default     = false
}

variable "enable_texporter" {
  description = "texporter (eBPF network-traffic metrics, needs linux-headers) on the client + texporter job."
  type        = bool
  default     = false
}

variable "enable_ffmpeg_exporter" {
  description = "ffmpeg_exporter (FFmpeg job metrics) on the client + ffmpeg job."
  type        = bool
  default     = false
}

variable "enable_script_exporter" {
  description = "script_exporter (arbitrary shell-script metrics) on the client + script job."
  type        = bool
  default     = false
}

variable "enable_vector" {
  description = "Vector pipeline service on the server (alt to OTel; future logging route)."
  type        = bool
  default     = false
}
