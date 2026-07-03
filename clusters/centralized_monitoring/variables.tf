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

# --- Cross-cluster scraping (opt-in; see specs/cross-cluster.md) -------------
# VMs in OTHER clusters that Prometheus should scrape. Empty by default keeps this cluster
# self-contained; `just up-connected` discovers peer clusters' VM IPs and writes this via a
# gitignored .cross-cluster.auto.tfvars.json. Each entry becomes one static-config scrape job.
variable "extra_scrape_targets" {
  description = "Cross-cluster scrape targets: list of {job, ip, port=9100}. Rendered as extra Prometheus static_configs jobs."
  type = list(object({
    job  = string
    ip   = string
    port = optional(number, 9100)
  }))
  default = []
}

# --- Cross-cluster log shipping (opt-in; see specs/cross-cluster.md) ---------
# host:port of the centralized_logging syslog-ng collector. Non-empty => the hub renders the
# shared syslog-ng client drop-in and ships its OWN OS logs there (the monitoring hub as a
# log-shipper, mirroring the consumer clusters). Empty by default keeps `just up` isolated.
# `just up-connected` sets this via the gitignored .cross-cluster.auto.tfvars.json.
variable "log_shipping_target" {
  description = "host:port of the centralized_logging syslog-ng collector. Empty disables self-shipping."
  type        = string
  default     = ""
}

# --- Cross-cluster DNS (opt-in; see specs/cross-cluster.md) ------------------
variable "dns_server" {
  description = "IP (or host[:port]) of the centralized_dns AdGuard Home resolver. Non-empty -> every VM points systemd-resolved at it at first boot. Empty (default) = image default resolver. See specs/cross-cluster.md."
  type        = string
  default     = ""
}

variable "internal_ca_cert" {
  description = "PEM of the internal root CA to trust on every VM. Non-empty -> each VM drops it into /usr/local/share/ca-certificates and runs update-ca-certificates at first boot. Empty (default) = no fleet trust. `just up-connected` injects it from centralized_pki. See specs/internal-ca.md."
  type        = string
  default     = ""
}

variable "ntp_server" {
  description = "IP (or host[:port]) of an internal NTP source. Non-empty -> every VM points systemd-timesyncd at it via /etc/systemd/timesyncd.conf.d/. Empty (default) = image default NTP pool. `just up-connected` (INTERNAL_NTP=1) wires it to the centralized_dns hub. See specs/shared-ntp.md."
  type        = string
  default     = ""
}

# --- Internal-CA TLS (opt-in; Phase 2, see specs/internal-ca.md) -------------
variable "use_internal_tls" {
  description = "Front the stack with Traefik serving an internal-CA leaf on :443. On -> the server issues a leaf from centralized_pki's step-ca at first boot (SANs grafana./prometheus./… .domain) and routes those hostnames over HTTPS; the plain http://IP:port ports stay published (additive). Needs ca_ip + stepca_ca_password wired (by `just up-connected` when the CA is up). Off (default) keeps `just up` turnkey/isolated. See specs/internal-ca.md §Phase 2."
  type        = bool
  default     = false
}

variable "domain" {
  description = "DNS suffix for internal service hostnames when use_internal_tls is on (grafana.<domain>, prometheus.<domain>, …). Must match centralized_pki's domain so the leaf chains + AdGuard rewrites resolve."
  type        = string
  default     = "lab.theblacktonystark.com"
}

variable "ca_ip" {
  description = "IPv4 of centralized_pki's step-ca VM, used at first boot to reach the CA (--add-host ca.<domain>) and issue the leaf. Empty (default) with use_internal_tls off = no TLS. `just up-connected` wires it from centralized_pki's ca_ipv4."
  type        = string
  default     = ""
}

variable "stepca_ca_password" {
  description = "step-ca JWK provisioner password used to issue the leaf. MUST match centralized_pki's var.stepca_ca_password. Sensitive; do not carry this lab default to Proxmox."
  type        = string
  default     = "changeit-dev-pki-only"
  sensitive   = true
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

# Interactive docker TUIs/inspectors (wharf, oxker, dive) on the docker VM (server). Not a
# /metrics exporter, so it is threaded straight into the server templatefile rather than via
# local.flags. All three ship native arm64 builds, so this defaults ON. See
# clusters/_shared/cloud-init/install-docker-tools.sh.
variable "enable_docker_tools" {
  description = "Install docker TUI/inspection tools (wharf, oxker, dive) on VMs running docker."
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
