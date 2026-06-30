variable "name_prefix" {
  description = "Prefix for Multipass instance names. Must use hyphens (underscores are invalid in Multipass names)."
  type        = string
  default     = "centralized-logging"
}

variable "image" {
  description = "Ubuntu image alias/version passed to multipass (e.g. \"24.04\")."
  type        = string
  default     = "24.04"
}

variable "syslog_port" {
  description = "TCP port the central syslog-ng server listens on and clients ship to."
  type        = number
  default     = 514
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

variable "hostname_source" {
  description = "How central derives $HOST for remote senders: 'keep' trusts the client-reported hostname (DNS-independent); 'dns' reverse-resolves the sender IP (needs PTR records); 'ip' folders by raw sender IP."
  type        = string
  default     = "keep"
  validation {
    condition     = contains(["keep", "dns", "ip"], var.hostname_source)
    error_message = "hostname_source must be one of: keep, dns, ip."
  }
}

# --- Metrics / exporter layer feature flags ---------------------------------
# Each flag gates an exporter's *install* in cloud-init (there is no local scrape to
# gate — see specs/centralized_logging_metrics.md). A disabled flag = not installed,
# not running, and skipped by the live test suite. Threaded into every templatefile()
# via local.flags in main.tf, mirroring the centralized_monitoring cluster.

variable "enable_node_exporter" {
  description = "node_exporter (:9100) on all VMs — host metrics; also serves the syslog-ng textfile .prom."
  type        = bool
  default     = true
}

variable "enable_syslogng_metrics" {
  description = "syslog-ng metrics on all VMs via node_exporter textfile collector (timer runs `syslog-ng-ctl stats prometheus`). Requires node_exporter."
  type        = bool
  default     = true
}

variable "enable_systemd_exporter" {
  description = "systemd_exporter (:9558) on all VMs — per-unit health (e.g. syslog-ng.service)."
  type        = bool
  default     = true
}

variable "enable_journald_exporter" {
  description = "journald-exporter (:12345) on all VMs. Default off: upstream ships an x86-64-only prebuilt binary, which does not run on the lab's arm64 VMs (works on amd64 Proxmox)."
  type        = bool
  default     = false
}

variable "enable_process_exporter" {
  description = "process-exporter (:9256) on all VMs — per-process CPU/mem (syslog-ng, dockerd, k0s)."
  type        = bool
  default     = true
}

variable "enable_filestat_exporter" {
  description = "filestat_exporter (:9943) on central only — size/mtime of /var/log/remote/* (detect a client that stopped shipping)."
  type        = bool
  default     = true
}

variable "enable_cadvisor" {
  description = "cAdvisor (:8089) on docker + k0s — container metrics (:8080 is taken by Traefik / kube-router)."
  type        = bool
  default     = true
}

variable "enable_traefik_metrics" {
  description = "Enable Traefik's Prometheus metrics endpoint (:8082) on the docker VM."
  type        = bool
  default     = true
}

variable "enable_kube_metrics" {
  description = "k0s only — expose kubelet read-only port (:10255) so kube-proxy (:10249) and kubelet/cAdvisor are scrapable without a token."
  type        = bool
  default     = true
}

variable "enable_kube_state_metrics" {
  description = "k0s only — kube-state-metrics (:8081) as a hostNetwork Deployment."
  type        = bool
  default     = true
}

variable "central" {
  description = "Resource sizing for the central logging VM."
  type = object({
    cpus   = number
    memory = string
    disk   = string
  })
  default = {
    cpus   = 2
    memory = "2G"
    disk   = "40G"
  }
}

variable "k0s_client" {
  description = "Resource sizing for the k0s single-node client VM."
  type = object({
    cpus   = number
    memory = string
    disk   = string
  })
  default = {
    cpus   = 2
    memory = "2G"
    disk   = "20G"
  }
}

variable "docker_client" {
  description = "Resource sizing for the Docker stack client VM."
  type = object({
    cpus   = number
    memory = string
    disk   = string
  })
  default = {
    cpus   = 2
    memory = "4G"
    disk   = "25G"
  }
}
