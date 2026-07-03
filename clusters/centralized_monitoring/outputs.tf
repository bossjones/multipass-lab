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

# Whether the docker operator TUIs (wharf/oxker/dive) are installed on the server VM.
# tests/testinfra/conftest.py reads this so the live suite skips (not fails) when off.
output "docker_tools_enabled" {
  description = "Whether the docker TUI/inspection tools (wharf, oxker, dive) are installed on the docker VM."
  value       = var.enable_docker_tools
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

# Browser URLs for `just open centralized_monitoring [--full]`. core = human dashboards
# on the server VM; all = core + every enabled exporter /metrics endpoint (server + k0s),
# each gated on the same enable_* flag that governs its install/scrape — so a disabled
# exporter never opens as a dead tab. URLs only (no passwords), so NOT sensitive.
locals {
  _server_ip = multipass_instance.server.ipv4
  _k0s_ip    = multipass_instance.k0s.ipv4

  web_urls_core = [for c in [
    { url = "http://${local._server_ip}", on = var.enable_heimdall },         # Heimdall homepage
    { url = "http://${local._server_ip}:3000", on = true },                   # Grafana
    { url = "http://${local._server_ip}:9090/targets", on = true },           # Prometheus
    { url = "http://${local._server_ip}:9093", on = true },                   # Alertmanager
    { url = "http://${local._server_ip}:5080", on = var.enable_openobserve }, # OpenObserve
    { url = "http://${local._server_ip}:3001", on = var.enable_uptime_kuma }, # Uptime Kuma
  ] : c.url if c.on]

  web_urls_metrics_candidates = [
    # server-side exporters
    { url = "http://${local._server_ip}:9100/metrics", on = var.enable_node_exporter },
    { url = "http://${local._server_ip}:8080/metrics", on = var.enable_cadvisor },
    { url = "http://${local._server_ip}:8888/metrics", on = var.enable_otel },
    { url = "http://${local._server_ip}:9115/metrics", on = var.enable_blackbox },
    { url = "http://${local._server_ip}:9102/metrics", on = var.enable_statsd_exporter },
    { url = "http://${local._server_ip}:9312/metrics", on = var.enable_ssh_exporter },
    { url = "http://${local._server_ip}:8686", on = var.enable_vector },
    { url = "http://${local._server_ip}:19999/api/v1/allmetrics?format=prometheus", on = var.enable_netdata },
    # k0s client exporters
    { url = "http://${local._k0s_ip}:9100/metrics", on = var.enable_node_exporter },
    { url = "http://${local._k0s_ip}:9256/metrics", on = var.enable_process_exporter },
    { url = "http://${local._k0s_ip}:9558/metrics", on = var.enable_systemd_exporter },
    { url = "http://${local._k0s_ip}:8089/metrics", on = var.enable_cadvisor },
    { url = "http://${local._k0s_ip}:19999/api/v1/allmetrics?format=prometheus", on = var.enable_netdata },
    { url = "http://${local._k0s_ip}:8081/metrics", on = var.enable_kube_state_metrics },
    { url = "http://${local._k0s_ip}:10255/metrics/cadvisor", on = var.enable_kubelet_scrape },
    { url = "http://${local._k0s_ip}:10249/metrics", on = var.enable_kubelet_scrape },
    { url = "http://${local._k0s_ip}:9943/metrics", on = var.enable_filestat_exporter },
    { url = "http://${local._k0s_ip}:9199/metrics", on = var.enable_nut_exporter },
    { url = "http://${local._k0s_ip}:9630/metrics", on = var.enable_nftables_exporter },
    { url = "http://${local._k0s_ip}:9450/metrics", on = var.enable_osquery_exporter },
    { url = "http://${local._k0s_ip}:9435/metrics", on = var.enable_ebpf_exporter },
    { url = "http://${local._k0s_ip}:9101/metrics", on = var.enable_texporter },
    { url = "http://${local._k0s_ip}:9618/metrics", on = var.enable_ffmpeg_exporter },
    { url = "http://${local._k0s_ip}:9469/probe", on = var.enable_script_exporter },
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
