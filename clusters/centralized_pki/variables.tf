variable "name_prefix" {
  description = "Prefix for Multipass instance names. Must use hyphens (underscores are invalid in Multipass names)."
  type        = string
  default     = "centralized-pki"
}

variable "image" {
  description = "Ubuntu image alias/version passed to multipass (e.g. \"24.04\")."
  type        = string
  default     = "24.04"
}

variable "domain" {
  description = "DNS suffix for internal services. Hostnames ca./auth./vault. live under this (e.g. auth.lab.theblacktonystark.com)."
  type        = string
  default     = "lab.theblacktonystark.com"
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

# --- Feature flags ----------------------------------------------------------
# Threaded into every templatefile() via local.flags in main.tf (mirrors the
# centralized_logging / centralized_monitoring clusters). enabled_flags is exported
# so the CLIs and testinfra suite parametrize over what is actually on.

variable "enable_letsencrypt_staging" {
  description = "OPT-IN. false (default) = Traefik gets browser certs from step-ca's internal ACME (hermetic, no external secrets). true = Traefik uses Let's Encrypt STAGING via DNS-01 (GoDaddy); requires godaddy_api_key/secret."
  type        = bool
  default     = false
}

variable "enable_node_exporter" {
  description = "node_exporter (:9100) on both VMs — host metrics; parity with the testinfra metrics pattern."
  type        = bool
  default     = true
}

# Interactive docker TUIs/inspectors (wharf, oxker, dive) on both VMs (both run docker). Not a
# /metrics exporter, so it is threaded straight into each templatefile rather than via
# local.flags. All three ship native arm64 builds, so this defaults ON. See
# clusters/_shared/cloud-init/install-docker-tools.sh.
variable "enable_docker_tools" {
  description = "Install docker TUI/inspection tools (wharf, oxker, dive) on VMs running docker."
  type        = bool
  default     = true
}

variable "enable_process_exporter" {
  description = "process-exporter (:9256) on both VMs — per-process metrics for step-ca, Traefik, Authelia."
  type        = bool
  default     = true
}

variable "enable_systemd_exporter" {
  description = "systemd_exporter (:9558) on both VMs — per-unit health/resource metrics."
  type        = bool
  default     = true
}

# --- Cross-cluster telemetry (opt-in; see specs/cross-cluster.md) ------------
# Empty defaults keep `just up centralized_pki` turnkey and isolated. `just up-connected`
# populates these via a gitignored .cross-cluster.auto.tfvars.json so this cluster's VMs ship
# logs to centralized_logging and push host logs to centralized_monitoring's OpenObserve.

variable "log_shipping_target" {
  description = "host:port of the centralized_logging syslog-ng collector. Non-empty -> both VMs render the syslog-ng client drop-in shipping to it. Empty (default) = disabled."
  type        = string
  default     = ""
}

variable "openobserve_endpoint" {
  description = "host:port of centralized_monitoring's OpenObserve. Non-empty -> both VMs run an otelcol-contrib agent pushing host logs via OTLP/HTTP. Empty (default) = disabled."
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

# --- Let's Encrypt staging (only consumed when enable_letsencrypt_staging = true) ---
# GoDaddy has no per-zone scoping; treat these as account-wide secrets. Never committed —
# pass via TF_VAR_godaddy_api_key / a gitignored *.auto.tfvars. See specs/centralized_pki.md.

variable "godaddy_api_key" {
  description = "GoDaddy Production API key (DNS-01). Only used when enable_letsencrypt_staging = true."
  type        = string
  default     = ""
  sensitive   = true
}

variable "godaddy_api_secret" {
  description = "GoDaddy Production API secret (DNS-01). Only used when enable_letsencrypt_staging = true."
  type        = string
  default     = ""
  sensitive   = true
}

variable "acme_email" {
  description = "Contact email for the ACME account (step-ca internal and, when enabled, LE staging)."
  type        = string
  default     = "pki@lab.theblacktonystark.com"
}

# --- Service secrets (dev defaults so `just up` is turnkey; document in DEFAULT_PASSWORDS.md) ---
# Every value below is rendered only into .rendered/ (gitignored) and mounted read-only in a
# container. Override any of them via TF_VAR_* for a non-throwaway deployment.

variable "stepca_ca_password" {
  description = "Password protecting the step-ca root/intermediate keys. Dev default; override via TF_VAR_stepca_ca_password."
  type        = string
  default     = "changeit-dev-pki-only"
  sensitive   = true
}

variable "authelia_user" {
  description = "Username for the single file-backend Authelia account."
  type        = string
  default     = "admin"
}

variable "authelia_password_hash" {
  description = "argon2id hash of the Authelia user's password. Dev default is Authelia's documented example hash for the plaintext 'password'."
  type        = string
  default     = "$argon2id$v=19$m=65536,t=3,p=4$BpLnfgDsc2WD8F2q$o/vzA4myCqZZ36bUGsDY//8mKUYNZZaR0t4MFFSs+iM"
  sensitive   = true
}

variable "authelia_session_secret" {
  description = "Authelia session secret (>= 20 chars). Dev default; override via TF_VAR_authelia_session_secret."
  type        = string
  default     = "dev-authelia-session-secret-change-me"
  sensitive   = true
}

variable "authelia_storage_key" {
  description = "Authelia storage encryption key (>= 20 chars). Dev default; override via TF_VAR_authelia_storage_key."
  type        = string
  default     = "dev-authelia-storage-encryption-key-change-me"
  sensitive   = true
}

variable "authelia_jwt_secret" {
  description = "Authelia identity-validation JWT secret. Dev default; override via TF_VAR_authelia_jwt_secret."
  type        = string
  default     = "dev-authelia-jwt-secret-change-me"
  sensitive   = true
}

variable "vaultwarden_admin_token" {
  description = "Vaultwarden /admin token. Dev default; override via TF_VAR_vaultwarden_admin_token (or set empty to disable /admin)."
  type        = string
  default     = "dev-vaultwarden-admin-token-change-me"
  sensitive   = true
}

# --- Per-role sizing --------------------------------------------------------

variable "ca" {
  description = "Resource sizing for the step-ca VM (step-ca is tiny)."
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

variable "services" {
  description = "Resource sizing for the Traefik/Authelia/Vaultwarden VM."
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
