output "server_ipv4" {
  description = "IPv4 address of the NetBox server VM. (`server_ipv4` name matches the observability CLIs' resolver.)"
  value       = multipass_instance.server.ipv4
}

output "client_ipv4" {
  description = "IPv4 address of the self-registering client VM."
  value       = multipass_instance.client.ipv4
}

# Consumed by tests/testinfra/conftest.py to build SSH testinfra hosts. The agent role is present
# only when enable_discovery (the VM is count-gated).
output "hosts" {
  description = "Map of role -> {name, ipv4} for every VM in the cluster (agent only when enable_discovery)."
  value = merge(
    {
      server = { name = local.server_name, ipv4 = multipass_instance.server.ipv4 }
      client = { name = local.client_name, ipv4 = multipass_instance.client.ipv4 }
    },
    var.enable_discovery ? {
      agent = { name = local.agent_name, ipv4 = multipass_instance.agent[0].ipv4 }
    } : {},
  )
}

output "netbox_url" {
  description = "Base URL of the NetBox API/UI. Consumed by netbox_cli.py and the testinfra suite."
  value       = "http://${multipass_instance.server.ipv4}:${var.netbox_port}"
}

output "netbox_api_token" {
  description = "Pinned LAB-ONLY NetBox API token (also the SUPERUSER_API_TOKEN). Exposed so the CLI/tests resolve it from `tofu output`."
  value       = var.netbox_api_token
}

output "netbox_cluster_name" {
  description = "The virtualization cluster the client registers into (netbox_cli check resolves this)."
  value       = var.cluster_name
}

output "netbox_site_name" {
  description = "The default DCIM site the bootstrap creates (netbox_cli check + testinfra resolve this)."
  value       = var.site_name
}

output "registered_vm_name" {
  description = "Name of the Virtual Machine the client is expected to self-register as (== the client VM name)."
  value       = local.client_name
}

output "netbox_region" {
  description = "DCIM Region the bootstrap seeds and nests the site under (netbox_cli/testinfra resolve this)."
  value       = var.netbox_region
}

output "netbox_rack_name" {
  description = "DCIM Rack the bootstrap seeds and mounts the host device in."
  value       = var.netbox_rack_name
}

output "netbox_host_device_name" {
  description = "DCIM Device (the Multipass host) the bootstrap seeds so /dcim/devices/ is populated; VMs link to it."
  value       = var.netbox_host_device_name
}

# The Multipass /24 the server sits on, derived from its DHCP IP (e.g. 192.168.252.0/24). The
# bootstrap seeds an IPAM Prefix for this subnet; the client's IP lands inside it. try() keeps
# hermetic (mock-provider) plans from erroring on a non-IP-shaped mock value.
output "netbox_prefix" {
  description = "IPAM Prefix (Multipass /24) the bootstrap seeds; the registered VM IPs fall inside it."
  value       = try("${join(".", slice(split(".", multipass_instance.server.ipv4), 0, 3))}.0/24", "")
}

# Discovery (opt-in Diode + orb-agent). These resolve to sane values whether or not discovery is
# enabled so `tofu output` / the CLI never error; consumers gate on discovery_enabled.
output "discovery_enabled" {
  description = "Whether the opt-in Diode/orb-agent discovery footprint is deployed."
  value       = var.enable_discovery
}

output "diode_url" {
  description = "Base URL of the Diode ingress (gRPC + HTTP multiplexed on nginx). orb-agent targets grpc://<host>:<diode_port>/diode."
  value       = "http://${multipass_instance.server.ipv4}:${var.diode_port}"
}

output "diode_metrics_url" {
  description = "Diode Prometheus /metrics URL (published when enable_discovery)."
  value       = "http://${multipass_instance.server.ipv4}:${var.diode_metrics_port}/metrics"
}

output "diode_ingest_client_id" {
  description = "OAuth2 client id orb-agent authenticates with (scope diode:ingest). The secret is a pinned LAB-ONLY var."
  value       = "diode-ingest"
}

# Browser URLs for `just open centralized_netbox [--full]`. core = the NetBox UI; all folds in
# the API root (handy for a quick token-less 200 check in the browser) plus, when discovery is on,
# the Diode /metrics endpoint.
output "web_urls" {
  description = "Browser URLs. core = NetBox UI; all = core + the REST API root (+ Diode /metrics when enable_discovery). Consumed by `just open <cluster> [--full]`."
  value = {
    core = ["http://${multipass_instance.server.ipv4}:${var.netbox_port}/"]
    all = concat(
      [
        "http://${multipass_instance.server.ipv4}:${var.netbox_port}/",
        "http://${multipass_instance.server.ipv4}:${var.netbox_port}/api/",
      ],
      var.enable_discovery ? ["http://${multipass_instance.server.ipv4}:${var.diode_metrics_port}/metrics"] : [],
    )
  }
}

output "shell_hints" {
  description = "Handy commands to poke at the cluster."
  value = join("\n", [
    "multipass shell ${local.server_name}",
    "multipass exec ${local.server_name} -- docker compose -f /opt/netbox-docker/docker-compose.yml ps",
    "curl -s http://${multipass_instance.server.ipv4}:${var.netbox_port}/api/status/ | jq .",
    "open http://${multipass_instance.server.ipv4}:${var.netbox_port}/  # NetBox UI (admin/admin)",
  ])
}
