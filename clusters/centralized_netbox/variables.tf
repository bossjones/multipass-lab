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

# --- base data-model seed --------------------------------------------------
# The server bootstrap seeds a realistic base data model on first boot (organization hierarchy,
# a DCIM device library, a rack + a real Device for the Multipass host, IPAM, tenancy) so a fresh
# NetBox is immediately useful. See specs/netbox-data.md. Only the names most likely to be
# customized per lab are variables; illustrative objects (device roles, platform, RIR, VLAN,
# contact) are sane-defaulted inside the seed script.

variable "netbox_region" {
  description = "DCIM Region the site is nested under (organization hierarchy)."
  type        = string
  default     = "Homelab"
}

variable "netbox_site_group" {
  description = "DCIM Site Group the site is grouped into."
  type        = string
  default     = "Multipass"
}

variable "netbox_location" {
  description = "DCIM Location within the site that holds the rack."
  type        = string
  default     = "Lab Rack Room"
}

variable "netbox_tenant" {
  description = "Tenant the site is assigned to."
  type        = string
  default     = "homelab"
}

variable "netbox_rack_name" {
  description = "Name of the DCIM Rack the Multipass host device is mounted in."
  type        = string
  default     = "multipass-rack-1"
}

variable "netbox_host_device_name" {
  description = "Name of the DCIM Device representing the physical Multipass host (populates /dcim/devices/; VMs link to it)."
  type        = string
  default     = "multipass-host"
}

variable "netbox_host_manufacturer" {
  description = "Manufacturer of the machine running Multipass (default Apple, since the lab host is a Mac). Override for a non-Mac host."
  type        = string
  default     = "Apple"
}

variable "netbox_host_model" {
  description = "Device-type model for the Multipass host device."
  type        = string
  default     = "Multipass Host"
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

# --- Prometheus exporters (both VMs; verified locally, scraped cross-cluster later) -----------
variable "enable_node_exporter" {
  description = "node_exporter (:9100) on both VMs — host metrics; parity with the other clusters."
  type        = bool
  default     = true
}

variable "enable_process_exporter" {
  description = "process-exporter (:9256) on both VMs — per-process metrics (NetBox workers, postgres, redis)."
  type        = bool
  default     = true
}

variable "enable_systemd_exporter" {
  description = "systemd_exporter (:9558) on both VMs — per-unit health/resource metrics."
  type        = bool
  default     = true
}
