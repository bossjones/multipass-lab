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

output "shell_hints" {
  description = "Handy commands to poke at the cluster."
  value = join("\n", [
    "multipass shell ${local.central_name}",
    "multipass exec ${local.central_name} -- sudo find /var/log/remote -type f",
    "open http://${multipass_instance.docker.ipv4}:8080  # traefik dashboard",
    "open http://${multipass_instance.docker.ipv4}:3000  # grafana (admin/admin)",
  ])
}
