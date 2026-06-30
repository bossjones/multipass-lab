output "central_ipv4" {
  description = "IPv4 address of the central logging VM."
  value       = multipass_instance.central.ipv4
}

output "k0s_ipv4" {
  description = "IPv4 address of the k0s client VM."
  value       = multipass_instance.k0s.ipv4
}

output "docker_ipv4" {
  description = "IPv4 address of the Docker client VM."
  value       = multipass_instance.docker.ipv4
}

# Consumed by tests/testinfra/conftest.py to build SSH testinfra hosts.
output "hosts" {
  description = "Map of role -> {name, ipv4} for every VM in the cluster."
  value = {
    central = { name = local.central_name, ipv4 = multipass_instance.central.ipv4 }
    k0s     = { name = local.k0s_name, ipv4 = multipass_instance.k0s.ipv4 }
    docker  = { name = local.docker_name, ipv4 = multipass_instance.docker.ipv4 }
  }
}

output "hostname_source" {
  description = "Active $HOST foldering strategy on central (keep | dns | ip)."
  value       = var.hostname_source
}

# Sorted list of active metrics enable_* flags. tests/testinfra parametrizes over this
# so a disabled exporter is skipped (not failed) in the live suite.
output "enabled_exporters" {
  description = "Sorted list of enabled metrics feature flags (the active exporter set)."
  value       = local.enabled_exporters
}

# Discovery map for the FUTURE centralized_monitoring scrape: role -> {ip, exporters{name=port}}.
# Fill cloud-init/prometheus/logging-scrape.yml from this (`tofu output -json metrics_targets`).
# All listeners bind 0.0.0.0, so these <ip>:<port> targets are scrapable cross-VM/cross-cluster.
output "metrics_targets" {
  description = "Per-role exporter endpoints for a future Prometheus to scrape."
  value = {
    central = {
      ip        = multipass_instance.central.ipv4
      exporters = { node = 9100, systemd = 9558, journald = 12345, process = 9256, filestat = 9943 }
    }
    docker = {
      ip        = multipass_instance.docker.ipv4
      exporters = { node = 9100, systemd = 9558, journald = 12345, process = 9256, cadvisor = 8089, traefik = 8082 }
    }
    k0s = {
      ip        = multipass_instance.k0s.ipv4
      exporters = { node = 9100, systemd = 9558, journald = 12345, process = 9256, cadvisor = 8089, kube_proxy = 10249, kubelet = 10255, kube_state = 8081 }
    }
  }
}

output "shell_hints" {
  description = "Handy commands to poke at the cluster."
  value = join("\n", [
    "multipass shell ${local.central_name}",
    "multipass exec ${local.central_name} -- sudo find /var/log/remote -type f",
    "open http://${multipass_instance.docker.ipv4}:8080  # traefik dashboard",
    "open http://${multipass_instance.docker.ipv4}:3000  # grafana (admin/admin)",
  ])
}
