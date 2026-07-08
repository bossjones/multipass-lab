# --- Identity / image / SSH -------------------------------------------------

variable "name_prefix" {
  description = "Prefix for Multipass instance names. Must use hyphens (underscores are invalid in Multipass names). VMs are named <prefix>-controller-N / -worker-M / -haproxy."
  type        = string
  default     = "centralized-k0s"
}

variable "image" {
  description = "Ubuntu image alias/version passed to multipass (e.g. \"24.04\")."
  type        = string
  default     = "24.04"
}

variable "ssh_pubkey_path" {
  description = "Path to the SSH public key injected into the ubuntu user (used by k0sctl over SSH + the testinfra verify loop). The matching private key (path minus .pub) is used by the post-apply provisioners."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_pubkey" {
  description = "Inline SSH public key. Overrides ssh_pubkey_path when non-empty (used by hermetic tests)."
  type        = string
  default     = ""
}

# --- Topology (count-driven; the control-plane count decides HA + HAProxy) ---

variable "k0s_control_plane_count" {
  description = "Number of k0s controller VMs. Default 1 (etcd single-member, no HAProxy, direct-to-controller-1). Set to 3 for the HA opt-in (3-member etcd quorum behind a conditional HAProxy edge). >1 also creates the HAProxy VM."
  type        = number
  default     = 1
}

variable "worker_count" {
  description = "Number of k0s worker VMs. Default 2 (fits `up-connected`). HA opt-in uses 3."
  type        = number
  default     = 2
}

# --- Per-role resource sizing ------------------------------------------------

variable "controller_size" {
  description = "Resource sizing for each controller VM (etcd + control plane + kubelet/cAdvisor via --enable-worker; 3G for etcd OOM headroom)."
  type = object({
    cpus   = number
    memory = string
    disk   = string
  })
  default = {
    cpus   = 3
    memory = "3G"
    disk   = "20G"
  }
}

variable "worker_size" {
  description = "Resource sizing for each worker VM."
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

variable "haproxy_size" {
  description = "Resource sizing for the HAProxy VM (only created when k0s_control_plane_count > 1)."
  type = object({
    cpus   = number
    memory = string
    disk   = string
  })
  default = {
    cpus   = 1
    memory = "1G"
    disk   = "10G"
  }
}

# --- k0s / tooling versions --------------------------------------------------

variable "k0s_version" {
  description = "Pinned k0s version (Kubernetes 1.34.9 / etcd 3.6.12). Threaded into K0S_VERSION (cloud-init get.k0s.sh) + k0sctl.yaml spec.k0s.version."
  type        = string
  default     = "v1.34.9+k0s.0"
}

variable "ksm_version" {
  description = "Pinned kube-state-metrics image version, applied post-apply via the k0s manifest deployer (never in cloud-init)."
  type        = string
  default     = "v2.13.0"
}

# --- CNI / observability flags ----------------------------------------------

variable "enable_cilium" {
  description = "Opt-in Cilium CNI (iteration 2; kube-router is the v1 default). CNI is immutable post-init, so this is a `just recreate`-class flag. Default off."
  type        = bool
  default     = false
}

variable "enable_netdata" {
  description = "Netdata real-time agent (:19999) on every node — per-second host/container/systemd metrics + built-in dashboards. Standalone (no Netdata Cloud), telemetry off. Default on."
  type        = bool
  default     = true
}

variable "enable_netdata_ebpf" {
  description = "Enable Netdata's eBPF collector (heaviest; arm64-stable availability varies). Default off — base install still runs all standard collectors."
  type        = bool
  default     = false
}

# --- Cross-cluster DNS / trust / NTP (opt-in, empty defaults) ----------------

variable "domain" {
  description = "DNS suffix for internal service hostnames. The stable k0s API endpoint is k0s-api.<domain> (spec.api.externalAddress → survives DHCP IP churn, so `k0s backup`/`restore` works). Registered into centralized_dns AdGuard via `just set-dns`."
  type        = string
  default     = "k0s.lab"
}

variable "dns_server" {
  description = "IP (or host[:port]) of the centralized_dns AdGuard Home resolver. Non-empty -> every VM points systemd-resolved at it at first boot. Empty (default) = image default resolver. See specs/cross-cluster.md."
  type        = string
  default     = ""
}

variable "internal_ca_cert" {
  description = "PEM of the internal root CA to trust on every VM. Non-empty -> each VM drops it into /usr/local/share/ca-certificates and runs update-ca-certificates at first boot. Empty (default) = no fleet trust. `just up-connected` injects it from centralized_pki."
  type        = string
  default     = ""
}

variable "ntp_server" {
  description = "IP (or host[:port]) of an internal NTP source. Non-empty -> every VM points systemd-timesyncd at it. Empty (default) = image default NTP pool. See specs/shared-ntp.md."
  type        = string
  default     = ""
}

# --- Log shipping to centralized_logging + centralized_monitoring (opt-in) ---
# Vector agent (one per node) ships host/k0s-component logs as syslog to
# centralized_logging and structured pod logs (path-parsed, no K8s API) to the
# monitoring hub's OpenObserve. All empty by default -> a plain `just up` is
# turnkey and isolated. `just up-connected` wires these from live hub IPs.

variable "log_shipping_target" {
  description = "host:port of the centralized_logging syslog-ng collector (TCP/514). Non-empty -> Vector ships host + k0s-component logs there as RFC5424 syslog. Empty (default) = no shipping."
  type        = string
  default     = ""
}

variable "openobserve_endpoint" {
  description = "host:port of centralized_monitoring's OpenObserve. Non-empty -> Vector ships structured pod logs to its /api/<org>/<stream>/_json endpoint. Empty (default) = no shipping."
  type        = string
  default     = ""
}

variable "openobserve_org" {
  description = "OpenObserve organization the pod-log _json ingest targets (root user's built-in org)."
  type        = string
  default     = ""
}

variable "openobserve_password" {
  description = "OpenObserve basic-auth password for the Vector http sink (must match the monitoring hub's OpenObserve root user)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "openobserve_stream" {
  description = "OpenObserve stream name in the /api/<org>/<stream>/_json ingest URL for pod logs. NEW value in the cross-cluster contract (the _json URL names the stream). Empty (default) = no shipping."
  type        = string
  default     = ""
}
