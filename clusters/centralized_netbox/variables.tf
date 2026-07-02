variable "name_prefix" {
  description = "Prefix for Multipass instance names. Must use lowercase + hyphens (underscores/uppercase are invalid in Multipass names)."
  type        = string
  default     = "centralized-netbox"
}

variable "image" {
  description = "Ubuntu image alias/version passed to multipass (e.g. \"24.04\")."
  type        = string
  default     = "24.04"
}

variable "netbox_port" {
  description = "Host TCP port NetBox is published on (netbox-docker override maps container 8080 -> this)."
  type        = number
  default     = 8000
}

variable "netbox_docker_ref" {
  description = <<-EOT
    Git ref of netbox-community/netbox-docker to clone on the server VM. Default "3.0.2" ships
    NetBox v4.1, which uses v1 *plaintext* API tokens (`Authorization: Token <40hex>`) so a pinned
    lab token works. NetBox 4.2+ switched to hashed v2 (Bearer) tokens where a known token value
    cannot be set — avoid unless you rework auth. A release tag pins both compose + image.
  EOT
  type        = string
  default     = "3.0.2"
}

variable "netbox_api_token" {
  description = <<-EOT
    LAB-ONLY pinned NetBox API token (40 hex chars). Injected as netbox-docker's
    SUPERUSER_API_TOKEN so self-registration and the verify CLI are deterministic. This is
    deliberately non-secret (throwaway VMs) and exposed via `tofu output`. Do NOT copy this
    pattern to Proxmox — generate + inject a real token from a secret store there.
  EOT
  type        = string
  default     = "0123456789abcdef0123456789abcdef01234567"

  validation {
    condition     = can(regex("^[0-9a-f]{40}$", var.netbox_api_token))
    error_message = "netbox_api_token must be exactly 40 lowercase hex characters (a NetBox token)."
  }
}

variable "netbox_superuser_name" {
  description = "NetBox superuser username created by netbox-docker on first boot (lab)."
  type        = string
  default     = "admin"
}

variable "netbox_superuser_password" {
  description = "NetBox superuser password (lab-only, netbox-docker SUPERUSER_PASSWORD)."
  type        = string
  default     = "admin"
}

variable "cluster_type" {
  description = "NetBox virtualization cluster-type the server bootstrap creates and the client registers under."
  type        = string
  default     = "Multipass"
}

variable "cluster_name" {
  description = "NetBox virtualization cluster the server bootstrap creates and the client registers into."
  type        = string
  default     = "centralized-netbox"
}

variable "site_name" {
  description = "Default DCIM site the server bootstrap creates. NetBox requires a site before any device can be added, so seeding one makes /dcim/devices/ usable out of the box."
  type        = string
  default     = "multipass-lab"
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
  description = "Resource sizing for the NetBox server VM (runs the full netbox-docker stack)."
  type = object({
    cpus   = number
    memory = string
    disk   = string
  })
  default = {
    cpus   = 2
    memory = "4G"
    disk   = "20G"
  }
}

variable "client" {
  description = "Resource sizing for the self-registering test VM (tiny)."
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
