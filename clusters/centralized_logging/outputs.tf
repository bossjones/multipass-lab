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

# Browser URLs for `just open centralized_logging [--full]`. The human dashboards all
# live on the docker VM and are always composed (so `core` is unconditional); `all`
# folds in every /metrics exporter endpoint, each gated on the same enable_* flag that
# governs its install in cloud-init — so a disabled exporter never opens as a dead tab.
locals {
  _docker_ip = multipass_instance.docker.ipv4

  # The 5 always-on docker-VM dashboards, plus the Coroot UI when enable_coroot. The Coroot URL
  # uses its NodePort (browser-friendly: no Host header needed, unlike the ingress path).
  web_urls_core = concat([
    "http://${local._docker_ip}",      # Heimdall (link homepage, fronted by Traefik :80)
    "http://${local._docker_ip}:3000", # Grafana (admin/admin)
    "http://${local._docker_ip}:9090", # Prometheus
    "http://${local._docker_ip}:9093", # Alertmanager
    "http://${local._docker_ip}:8080", # Traefik dashboard
    ], var.enable_coroot ? [
    "http://${multipass_instance.k0s.ipv4}:${var.coroot_nodeport}", # Coroot UI (eBPF observability)
  ] : [])

  # One {url, on} candidate per (role, exporter); the same port map as metrics_targets.
  web_urls_metrics_candidates = [
    # central
    { url = "http://${multipass_instance.central.ipv4}:9100/metrics", on = var.enable_node_exporter },
    { url = "http://${multipass_instance.central.ipv4}:9558/metrics", on = var.enable_systemd_exporter },
    { url = "http://${multipass_instance.central.ipv4}:12345/metrics", on = var.enable_journald_exporter },
    { url = "http://${multipass_instance.central.ipv4}:9256/metrics", on = var.enable_process_exporter },
    { url = "http://${multipass_instance.central.ipv4}:9943/metrics", on = var.enable_filestat_exporter },
    # docker
    { url = "http://${local._docker_ip}:9100/metrics", on = var.enable_node_exporter },
    { url = "http://${local._docker_ip}:9558/metrics", on = var.enable_systemd_exporter },
    { url = "http://${local._docker_ip}:12345/metrics", on = var.enable_journald_exporter },
    { url = "http://${local._docker_ip}:9256/metrics", on = var.enable_process_exporter },
    { url = "http://${local._docker_ip}:8089/metrics", on = var.enable_cadvisor },
    { url = "http://${local._docker_ip}:8082/metrics", on = var.enable_traefik_metrics },
    # k0s
    { url = "http://${multipass_instance.k0s.ipv4}:9100/metrics", on = var.enable_node_exporter },
    { url = "http://${multipass_instance.k0s.ipv4}:9558/metrics", on = var.enable_systemd_exporter },
    { url = "http://${multipass_instance.k0s.ipv4}:12345/metrics", on = var.enable_journald_exporter },
    { url = "http://${multipass_instance.k0s.ipv4}:9256/metrics", on = var.enable_process_exporter },
    { url = "http://${multipass_instance.k0s.ipv4}:8089/metrics", on = var.enable_cadvisor },
    { url = "http://${multipass_instance.k0s.ipv4}:10249/metrics", on = var.enable_kube_metrics },
    { url = "http://${multipass_instance.k0s.ipv4}:10255/metrics/cadvisor", on = var.enable_kube_metrics },
    { url = "http://${multipass_instance.k0s.ipv4}:8081/metrics", on = var.enable_kube_state_metrics },
    # netdata built-in dashboard on every VM (real-time agent)
    { url = "http://${multipass_instance.central.ipv4}:19999", on = var.enable_netdata },
    { url = "http://${local._docker_ip}:19999", on = var.enable_netdata },
    { url = "http://${multipass_instance.k0s.ipv4}:19999", on = var.enable_netdata },
  ]
  web_urls_metrics = [for c in local.web_urls_metrics_candidates : c.url if c.on]
}

output "web_urls" {
  description = "Browser URLs. core = human dashboards; all = core + enabled /metrics endpoints. Consumed by `just open <cluster> [--full]`."
  value = {
    core = local.web_urls_core
    all  = concat(local.web_urls_core, local.web_urls_metrics)
  }
}

# Opt-in non-exporter features (Coroot + ingress). tests/testinfra/conftest.py reads this so the
# live Coroot suite is *skipped* (not failed) when the feature is off — mirrors enabled_exporters.
output "enabled_features" {
  description = "Opt-in feature flags beyond the exporter layer: { coroot, ingress }."
  value = {
    coroot  = var.enable_coroot
    ingress = var.enable_ingress
  }
}

# Coroot deployment info — consumed by the `just coroot-*` recipes and the live test suite.
output "coroot" {
  description = "Coroot deployment info: enabled flags, the browser-friendly NodePort UI URL, and the ingress host."
  value = {
    enabled      = var.enable_coroot
    ingress      = var.enable_ingress
    nodeport     = var.coroot_nodeport
    nodeport_url = "http://${multipass_instance.k0s.ipv4}:${var.coroot_nodeport}"
    ingress_host = var.coroot_host
  }
}
