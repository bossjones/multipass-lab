variable "name_prefix" {
  description = "Prefix for Multipass instance names. Must use hyphens (underscores are invalid in Multipass names)."
  type        = string
  default     = "centralized-dns"
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

# --- AdGuard Home ------------------------------------------------------------
# The web UI + control API are served on adguard_web_port; DNS is always 0.0.0.0:53.
# Credentials are DEV-THROWAWAY (see DEFAULT_PASSWORDS.md) and exposed via `tofu output`
# on purpose (throwaway lab VM). The exporter + CLIs need the PLAINTEXT password; the
# seeded AdGuardHome.yaml needs the BCRYPT hash. Changing the password means regenerating
# the hash (`AdGuardHome --hash-password` or `htpasswd -B`). Override both together via
# TF_VAR_adguard_password / TF_VAR_adguard_password_hash for a non-throwaway deployment.

variable "adguard_user" {
  description = "AdGuard Home admin username (web UI + control API + exporter)."
  type        = string
  default     = "admin"
}

variable "adguard_password" {
  description = "AdGuard Home admin PLAINTEXT password. Dev default; must match adguard_password_hash. Override via TF_VAR_adguard_password."
  type        = string
  default     = "test1234"
  sensitive   = true
}

variable "adguard_password_hash" {
  description = "BCRYPT hash of adguard_password, seeded into AdGuardHome.yaml (skips the setup wizard). Dev default is bcrypt('test1234'). Regenerate when changing adguard_password."
  type        = string
  default     = "$2y$10$9BVgnjg36iNcb3mnzovTQuySK8GmG/aTmQvuY1hCjd1vuT/lYjLyC"
  sensitive   = true
}

variable "adguard_web_port" {
  description = "Port for the AdGuard Home web UI + /control API (matches adguardctl's default of 3000)."
  type        = number
  default     = 3000
}

variable "upstream_unbound" {
  description = "AdGuard Home upstream DNS — the local Unbound recursive resolver. host:port."
  type        = string
  default     = "127.0.0.1:5335"
}

variable "blocklists" {
  description = "AdGuard Home filter lists (name + url). Rendered into the seeded AdGuardHome.yaml with sequential ids. Default = the reference homelab set (AdGuard DNS filter, AdAway, HaGeZi, uBlock, bossjones)."
  type = list(object({
    name = string
    url  = string
  }))
  default = [
    { name = "AdGuard DNS filter", url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt" },
    { name = "AdAway Default Blocklist", url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt" },
    { name = "HaGeZi's Pro Blocklist", url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_48.txt" },
    { name = "uBlock filters - Badware risks", url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_50.txt" },
    { name = "HaGeZi's Pro++ Blocklist", url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_51.txt" },
    { name = "bossjones pi-hole to adguard list", url = "https://raw.githubusercontent.com/bossjones/dns-blocklist/refs/heads/main/stevenblack-blocklist-pihole-to-adguard.txt" },
  ]
}

# --- DNS rewrites (opt-in; internal-CA TLS hostname resolution, see specs/internal-ca.md) -----
variable "dns_rewrites" {
  description = "AdGuard Home host rewrites (domain -> answer IP) seeded into AdGuardHome.yaml. Used by Phase 2 internal-CA TLS so `grafana.<domain>` etc. resolve to the fronting service's IP for green-lock browsing. Empty (default) = none. `just dns-register <cluster>` populates + hot-pushes these to the running hub."
  type = list(object({
    domain = string
    answer = string
  }))
  default = []
}

# --- Exporter versions -------------------------------------------------------

variable "adguard_exporter_version" {
  description = "henrywhitaker3/adguard-exporter release tag (Prometheus metrics on :9618)."
  type        = string
  default     = "v1.2.1"
}

# --- Feature flags (exporters) ----------------------------------------------
# Threaded into the cloud-init render via local.flags; enabled_flags is exported so the
# CLIs + testinfra suite parametrize over what is actually on (mirrors the other clusters).

variable "enable_node_exporter" {
  description = "node_exporter (:9100) — OS host metrics; parity with the other clusters' metrics tests."
  type        = bool
  default     = true
}

variable "enable_unbound_exporter" {
  description = "unbound_exporter (:9167) — Unbound resolver metrics via its control socket."
  type        = bool
  default     = true
}

variable "enable_adguard_exporter" {
  description = "adguard-exporter (:9618) — AdGuard Home metrics via its control API."
  type        = bool
  default     = true
}

variable "enable_process_exporter" {
  description = "process-exporter (:9256) — per-process metrics for AdGuardHome/unbound."
  type        = bool
  default     = true
}

variable "enable_systemd_exporter" {
  description = "systemd_exporter (:9558) — per-unit health/resource metrics."
  type        = bool
  default     = true
}

# --- Cross-cluster telemetry (opt-in; see specs/cross-cluster.md) ------------
# Empty defaults keep `just up centralized_dns` turnkey and isolated. `just up-connected`
# hot-pushes these once the logging/monitoring hubs exist (this cluster boots FIRST).

variable "dns_server" {
  description = "IP (or host[:port]) of an AdGuard Home resolver to point THIS VM's systemd-resolved at. For centralized_dns this stays empty — the VM resolves through its OWN AdGuard (127.0.0.1). Present for contract symmetry. See specs/cross-cluster.md."
  type        = string
  default     = ""
}

variable "internal_ca_cert" {
  description = "PEM of the internal root CA to trust on every VM. Non-empty -> each VM drops it into /usr/local/share/ca-certificates and runs update-ca-certificates at first boot. Empty (default) = no fleet trust. `just up-connected` injects it from centralized_pki. See specs/internal-ca.md."
  type        = string
  default     = ""
}

variable "log_shipping_target" {
  description = "host:port of the centralized_logging syslog-ng collector. Non-empty -> the VM renders the syslog-ng client drop-in shipping to it. Empty (default) = disabled."
  type        = string
  default     = ""
}

variable "openobserve_endpoint" {
  description = "host:port of centralized_monitoring's OpenObserve. Non-empty -> the VM runs an otelcol-contrib agent pushing host logs via OTLP/HTTP. Empty (default) = disabled."
  type        = string
  default     = ""
}

variable "openobserve_org" {
  description = "OpenObserve org used in the OTLP push URL (only consumed when openobserve_endpoint is set)."
  type        = string
  default     = "default"
}

variable "openobserve_password" {
  description = "OpenObserve root password for the OTLP Basic auth header. Dev default matches centralized_monitoring; override via TF_VAR_openobserve_password."
  type        = string
  default     = "Complexpass#123"
  sensitive   = true
}

# --- Sizing ------------------------------------------------------------------

variable "server" {
  description = "Resource sizing for the DNS VM (AdGuard Home + Unbound + exporters are light)."
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
