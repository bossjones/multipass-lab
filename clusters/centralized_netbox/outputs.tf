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

# Browser URLs for `just open centralized_netbox [--full]`. core = the NetBox UI; all folds in
# the API root (handy for a quick token-less 200 check in the browser).
output "web_urls" {
  description = "Browser URLs. core = NetBox UI; all = core + the REST API root. Consumed by `just open <cluster> [--full]`."
  value = {
    core = ["http://${multipass_instance.server.ipv4}:${var.netbox_port}/"]
    all = [
      "http://${multipass_instance.server.ipv4}:${var.netbox_port}/",
      "http://${multipass_instance.server.ipv4}:${var.netbox_port}/api/",
    ]
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
