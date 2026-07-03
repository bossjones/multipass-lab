variable "name_prefix" {
  description = "Prefix for Multipass instance names. Must use hyphens (underscores are invalid in Multipass names)."
  type        = string
  default     = "centralized-unifi"
}

variable "image" {
  description = "Ubuntu image alias/version passed to multipass for the VM host (e.g. \"24.04\"). The period-exact Debian daemons run in containers INSIDE this VM, not as the VM OS."
  type        = string
  default     = "24.04"
}

variable "syslog_port" {
  description = "syslog port: the controller's network() collector listens here and the USG's rsyslog forwards to it (UDP, matching the appliance's `@host:port`)."
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

# --- Cross-cluster (opt-in) --------------------------------------------------
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

# --- Fidelity model ----------------------------------------------------------
# `exact` (default): run the appliances' ACTUAL Debian packages in containers —
#   syslog-ng 3.28.1 (bullseye, native arm64) + rsyslog 5.8.11 (wheezy, emulated amd64),
#   with the legacy-CSV syslog_ng_exporter (:9577) that works on 3.28.1 (matches the real UCK).
# `modern`: run Ubuntu-stock syslog-ng 4.x / rsyslog 8.x on the bare VM with the native
#   `syslog-ng-ctl stats prometheus` textfile exporter — for prototyping the native path.
# See specs/centralized_unifi.md ("Fidelity model").
variable "version_mode" {
  description = "How the daemons are delivered: 'exact' (period Debian packages in containers) or 'modern' (Ubuntu-stock packages on the bare VM)."
  type        = string
  default     = "exact"
  validation {
    condition     = contains(["exact", "modern"], var.version_mode)
    error_message = "version_mode must be one of: exact, modern."
  }
}

# Pinned Debian package versions + base images (exact mode). Kept as variables so a version bump
# is a one-line change and the hermetic tests can assert the pins are rendered into cloud-init.
variable "syslogng_deb_version" {
  description = "Exact Debian bullseye syslog-ng package version for the controller container (the UCK Gen2's version)."
  type        = string
  default     = "3.28.1-2+deb11u2"
}

variable "rsyslog_deb_version" {
  description = "Exact Debian wheezy rsyslog package version for the USG container (the USG's version)."
  type        = string
  default     = "5.8.11-3+deb7u2"
}

variable "controller_base_image" {
  description = "Base image for the syslog-ng (UCK) container. bullseye ships syslog-ng 3.28.1 and has a native arm64 build."
  type        = string
  default     = "debian:bullseye"
}

variable "usg_base_image" {
  description = "Base image for the rsyslog (USG) container. wheezy ships rsyslog 5.8.11; it is EOL (installs from archive.debian.org) and amd64-only (emulated on arm64)."
  type        = string
  default     = "debian/eol:wheezy"
}

variable "usg_platform" {
  description = "Docker platform for the USG container. wheezy has no arm64 port, so on Apple Silicon this runs emulated as linux/amd64."
  type        = string
  default     = "linux/amd64"
}

# --- Feature flags -----------------------------------------------------------
variable "enable_node_exporter" {
  description = "node_exporter (:9100) on each VM host — OS metrics for both VMs."
  type        = bool
  default     = true
}

variable "enable_syslogng_exporter" {
  description = "brandond/syslog_ng_exporter (:9577) sidecar on the controller — legacy-CSV syslog-ng stats over the control socket (the exporter path that works on syslog-ng 3.28.1, i.e. the real UCK)."
  type        = bool
  default     = true
}

variable "enable_unifi_traffic" {
  description = "Run the USG traffic generator (Vyatta/firewall-style logger lines, incl. local7 + [ALIEN BLOCK]/[TOR BLOCK] markers) so the pipeline shows live data and exporter counters move."
  type        = bool
  default     = true
}

# Interactive docker TUIs/inspectors (wharf, oxker, dive). Both VMs only run docker in the
# `exact` version_mode (modern mode runs bare-metal rsyslog/syslog-ng), so the installer is
# gated on (enable_docker_tools && exact) in cloud-init. All three ship native arm64 builds,
# so this defaults ON. See clusters/_shared/cloud-init/install-docker-tools.sh.
variable "enable_docker_tools" {
  description = "Install docker TUI/inspection tools (wharf, oxker, dive) on VMs running docker (exact mode only)."
  type        = bool
  default     = true
}

# --- Resource sizing ---------------------------------------------------------
variable "controller" {
  description = "Resource sizing for the controller VM (Ubuntu host + native-arm64 syslog-ng container + exporter)."
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

variable "usg" {
  description = "Resource sizing for the USG VM (Ubuntu host + emulated-amd64 wheezy rsyslog container — emulation wants headroom)."
  type = object({
    cpus   = number
    memory = string
    disk   = string
  })
  default = {
    cpus   = 2
    memory = "2G"
    disk   = "15G"
  }
}
