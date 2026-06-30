output "server_ipv4" {
  description = "IPv4 address of the observability server VM."
  value       = multipass_instance.server.ipv4
}

output "k0s_ipv4" {
  description = "IPv4 address of the monitored k0s client VM."
  value       = multipass_instance.k0s.ipv4
}

# Consumed by tests/testinfra/conftest.py to build SSH testinfra hosts.
output "hosts" {
  description = "Map of role -> {name, ipv4} for every VM in the cluster."
  value = {
    server = { name = local.server_name, ipv4 = multipass_instance.server.ipv4 }
    k0s    = { name = local.k0s_name, ipv4 = multipass_instance.k0s.ipv4 }
  }
}

# Sorted list of active enable_* flags. tests/testinfra parametrizes over this so a
# disabled exporter is skipped (not failed) in the live suite.
output "enabled_exporters" {
  description = "Sorted list of enabled feature flags (the active exporter/integration set)."
  value       = local.enabled_exporters
}

output "shell_hints" {
  description = "Handy commands / URLs to poke at the cluster."
  value = join("\n", [
    "just ssh centralized_monitoring server",
    "open http://${multipass_instance.server.ipv4}:9090/targets   # prometheus targets",
    "open http://${multipass_instance.server.ipv4}:3000           # grafana (admin/${var.grafana_admin_password})",
    "open http://${multipass_instance.server.ipv4}:5080           # openobserve",
    "open http://${multipass_instance.server.ipv4}:3001           # uptime kuma",
  ])
  sensitive = true
}
