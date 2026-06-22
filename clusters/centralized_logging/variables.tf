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
