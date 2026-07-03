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
    lab token works. Pinnable v1 tokens survive through NetBox **4.4.x**; **NetBox 4.5+** introduced
    hashed v2 (`Authorization: Bearer nbt_<KEY>.<TOKEN>`) tokens where a known value cannot be set,
    and v1 is removed entirely in 4.7 — bumping past 4.4.x needs an auth rework (see
    specs/netbox-discovery.md). A release tag pins both compose + image. (The opt-in discovery path
    uses var.netbox_docker_ref_discovery, a 4.4.x pin, precisely to stay in the v1-token band.)
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

# --- discovery (opt-in: NetBox Labs Diode + orb-agent) ---------------------
# enable_discovery gates the entire discovery footprint (custom NetBox plugin image + the Diode
# server stack + a third orb-agent VM). Default OFF: with it off the cluster is byte-for-byte what
# it is today (NetBox 4.1, pinned v1 token, self-registration). See specs/netbox-discovery.md.
# Enabling it is a cloud-init change, so it needs `just recreate centralized_netbox` (not `up`).

variable "enable_discovery" {
  description = <<-EOT
    Opt-in: stand up NetBox Labs Discovery (Diode ingestion server + diode-netbox-plugin + an
    orb-agent VM that scans the Multipass /24). Default false. When true the server is bumped to
    var.netbox_docker_ref_discovery (NetBox 4.4.x — keeps pinnable v1 tokens AND satisfies Diode's
    NetBox >= 4.2.3 requirement; the hashed-v2 token cliff is 4.5, not 4.2), a custom plugin image
    is built, the Diode stack is deployed, and a third VM runs discovery. Requires `just recreate`.
  EOT
  type        = bool
  default     = false
}

variable "netbox_docker_ref_discovery" {
  description = <<-EOT
    netbox-docker git ref used ONLY when enable_discovery is true. Must ship a NetBox in the
    4.2.3..4.4.x band: Diode requires >= 4.2.3, and 4.4.x is the highest release that still uses
    pinnable v1 plaintext tokens (4.5 introduced hashed v2/Bearer tokens). "3.4.1" ships NetBox
    4.4.x (image netboxcommunity/netbox:v4.4-3.4.1). Confirm the exact 4.4.x <-> plugin pairing in
    the Phase 0 spike (see specs/netbox-discovery.md).
  EOT
  type        = string
  default     = "3.4.1"
}

variable "diode_plugin_version" {
  description = <<-EOT
    Pinned netboxlabs-diode-netbox-plugin version, paired with the NetBox the discovery image ships.
    netbox-docker 3.4.1 ships NetBox 4.4.5, and plugin 1.7.0 requires NetBox >= 4.4.10 (it silently
    refuses to load otherwise) — so 4.4.5 pairs with plugin 1.4.1 (compat table: NetBox 4.4.0 ->
    1.4.0/1.4.1). Bump BOTH together if you move netbox_docker_ref_discovery to a >= 4.4.10 image.
  EOT
  type        = string
  default     = "1.4.1"
}

variable "diode_tag" {
  description = <<-EOT
    Image tag for the netboxlabs/diode-{ingester,reconciler,auth} server images (DIODE_TAG, consumed
    by the Diode .env). Pinned to "2.0.0" — the only tag that exists consistently across all three
    images (diode-auth lags at 1.12.0 on the 1.13.0 line, so 1.13.0 is NOT a usable single tag) and
    confirmed linux/arm64-native for the Apple-Silicon lab host. It matches the `release`-branch
    compose this cluster vendors. See specs/netbox-discovery.md.
  EOT
  type        = string
  default     = "2.0.0"
}

variable "orb_agent_image" {
  description = "orb-agent container image run on the discovery agent VM. Confirm linux/arm64 availability in Phase 0 (the lab host is Apple Silicon)."
  type        = string
  default     = "netboxlabs/orb-agent:latest"
}

variable "diode_port" {
  description = "Host TCP port the Diode nginx ingress is published on (gRPC + HTTP multiplexed). orb-agent targets grpc://<server>:<diode_port>/diode."
  type        = number
  default     = 8080
}

# NOTE: the real netboxlabs/diode release publishes NO per-service metrics ports (the diode images
# are distroless with no EXPOSE and no TELEMETRY_METRICS_PORT; prometheus is scraped internally). The
# previous representative config invented a 9090 publish; it has been removed so the compose matches
# the release. Only the nginx ingress (var.diode_port) is published to the host.

# Pinned LAB-ONLY OAuth2 client secrets (Ory Hydra client-credentials). We render Diode's
# client-credentials.json + .env with these fixed values instead of running quickstart.sh (which
# randomizes them at runtime and would break this repo's render-time secret model). Same throwaway
# philosophy as netbox_api_token — deliberately non-secret, exposed via `tofu output`. DO NOT copy
# to Proxmox: generate + inject real secrets from a secret store there.

variable "diode_ingest_client_secret" {
  description = "LAB-ONLY pinned secret for the `diode-ingest` OAuth2 client (scope diode:ingest). Held by orb-agent."
  type        = string
  default     = "lab-diode-ingest-secret-000000000000"

  validation {
    condition     = length(var.diode_ingest_client_secret) >= 16
    error_message = "diode_ingest_client_secret must be at least 16 characters."
  }
}

variable "diode_to_netbox_client_secret" {
  description = "LAB-ONLY pinned secret for the `diode-to-netbox` OAuth2 client (scope netbox:read netbox:write). Held by the Diode reconciler."
  type        = string
  default     = "lab-diode-to-netbox-secret-000000000000"

  validation {
    condition     = length(var.diode_to_netbox_client_secret) >= 16
    error_message = "diode_to_netbox_client_secret must be at least 16 characters."
  }
}

variable "netbox_to_diode_client_secret" {
  description = "LAB-ONLY pinned secret for the `netbox-to-diode` OAuth2 client (scope diode:read diode:write). Held by the NetBox plugin (PLUGINS_CONFIG)."
  type        = string
  default     = "lab-netbox-to-diode-secret-000000000000"

  validation {
    condition     = length(var.netbox_to_diode_client_secret) >= 16
    error_message = "netbox_to_diode_client_secret must be at least 16 characters."
  }
}

# Pinned LAB-ONLY infra secrets for the Diode stack's own Redis / Postgres / Hydra.
variable "diode_redis_password" {
  description = "LAB-ONLY pinned Redis password for the Diode stack."
  type        = string
  default     = "lab-diode-redis-000000000000"
}

variable "diode_postgres_password" {
  description = "LAB-ONLY pinned Postgres password for the Diode stack (the `diode` DB)."
  type        = string
  default     = "lab-diode-postgres-000000000000"
}

variable "diode_hydra_system_secret" {
  description = "LAB-ONLY pinned Ory Hydra system secret (HYDRA_SECRETS_SYSTEM_0)."
  type        = string
  default     = "lab-diode-hydra-system-000000000000"
}

variable "agent" {
  description = "Resource sizing for the discovery agent VM (only created when enable_discovery). Tiny — just docker + orb-agent."
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

variable "dns_server" {
  description = "IP (or host[:port]) of the centralized_dns AdGuard Home resolver. Non-empty -> every VM points systemd-resolved at it at first boot. Empty (default) = image default resolver. See specs/cross-cluster.md."
  type        = string
  default     = ""
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

# Interactive docker TUIs/inspectors (wharf, oxker, dive) on the docker VMs (server always;
# discovery agent when enable_discovery). The client VM has no docker and is left out. Not a
# /metrics exporter, so it is threaded straight into those templatefiles. All three ship native
# arm64 builds, so this defaults ON. See clusters/_shared/cloud-init/install-docker-tools.sh.
variable "enable_docker_tools" {
  description = "Install docker TUI/inspection tools (wharf, oxker, dive) on VMs running docker."
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

# --- Opt-in observability ----------------------------------------------------
variable "enable_netdata" {
  description = "Netdata real-time agent (:19999, /api/v1/allmetrics?format=prometheus) on both VMs — per-second host/container metrics + built-in dashboards. Standalone (no Netdata Cloud), telemetry off. No local Prometheus here, so dashboard-only."
  type        = bool
  default     = true
}
