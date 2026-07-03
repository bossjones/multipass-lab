output "server_ipv4" {
  description = "IPv4 address of the NetBox server VM. (`server_ipv4` name matches the observability CLIs' resolver.)"
  value       = multipass_instance.server.ipv4
}

output "client_ipv4" {
  description = "IPv4 address of the self-registering client VM."
  value       = multipass_instance.client.ipv4
}

# Consumed by tests/testinfra/conftest.py to build SSH testinfra hosts.
output "hosts" {
  description = "Map of role -> {name, ipv4} for every VM in the cluster."
  value = {
    server = { name = local.server_name, ipv4 = multipass_instance.server.ipv4 }
    client = { name = local.client_name, ipv4 = multipass_instance.client.ipv4 }
  }
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

# Sorted list of active enable_* flags. tests/testinfra parametrizes over this so the live
# suite asserts only the exporters that are on.
output "enabled_exporters" {
  description = "Sorted list of enabled exporter flags (the active exporter set)."
  value       = local.enabled_exporters
}

# Browser URLs for `just open centralized_netbox [--full]`. core = the NetBox UI; all folds in
# the API root plus every enabled exporter /metrics endpoint (server + client).
locals {
  _web_urls_metrics_candidates = [
    { url = "http://${multipass_instance.server.ipv4}:9100/metrics", on = var.enable_node_exporter },
    { url = "http://${multipass_instance.server.ipv4}:9256/metrics", on = var.enable_process_exporter },
    { url = "http://${multipass_instance.server.ipv4}:9558/metrics", on = var.enable_systemd_exporter },
    { url = "http://${multipass_instance.client.ipv4}:9100/metrics", on = var.enable_node_exporter },
    { url = "http://${multipass_instance.client.ipv4}:9256/metrics", on = var.enable_process_exporter },
    { url = "http://${multipass_instance.client.ipv4}:9558/metrics", on = var.enable_systemd_exporter },
  ]
  _web_urls_metrics = [for c in local._web_urls_metrics_candidates : c.url if c.on]
}

output "web_urls" {
  description = "Browser URLs. core = NetBox UI; all = core + the REST API root + enabled /metrics endpoints. Consumed by `just open <cluster> [--full]`."
  value = {
    core = ["http://${multipass_instance.server.ipv4}:${var.netbox_port}/"]
    all = concat([
      "http://${multipass_instance.server.ipv4}:${var.netbox_port}/",
      "http://${multipass_instance.server.ipv4}:${var.netbox_port}/api/",
    ], local._web_urls_metrics)
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
