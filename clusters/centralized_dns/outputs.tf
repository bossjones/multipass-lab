output "server_ipv4" {
  description = "IPv4 address of the DNS VM (AdGuard Home :53 + web UI, Unbound upstream)."
  value       = multipass_instance.server.ipv4
}

# Consumed by tests/testinfra/conftest.py to build SSH testinfra hosts, and by up-connected.
output "hosts" {
  description = "Map of role -> {name, ipv4} for every VM in the cluster."
  value = {
    server = { name = local.server_name, ipv4 = multipass_instance.server.ipv4 }
  }
}

# Service hostname -> IP A-records for the fleet resolver. `just set-dns` reads this and registers
# each as an AdGuard rewrite so these names resolve fleet-wide.
output "dns_records" {
  description = "hostname -> ipv4 A-records to register in centralized_dns AdGuard. Consumed by `just set-dns`."
  value = {
    "adguard.${var.domain}" = multipass_instance.server.ipv4
    "dns.${var.domain}"     = multipass_instance.server.ipv4
  }
}

output "adguard_url" {
  description = "AdGuard Home web UI + /control API base URL."
  value       = "http://${multipass_instance.server.ipv4}:${var.adguard_web_port}"
}

# Routes the fleet-edge Traefik (centralized_pki) should publish for this cluster. Consumed by
# scripts/traefik_cli.py (see specs/dynamic-traefik.md).
output "reverse_proxy_routes" {
  description = "Routes the fleet-edge Traefik should publish for this cluster. Consumed by scripts/traefik_cli.py."
  value = [
    { host = "adguard", ip = multipass_instance.server.ipv4, port = var.adguard_web_port, scheme = "http", sso = false, k0s = false },
  ]
}

output "adguard_credentials" {
  description = "Dev-throwaway AdGuard Home admin credentials (lab only — do NOT reuse). Consumed by the CLIs."
  sensitive   = true
  value = {
    user     = var.adguard_user
    password = var.adguard_password
  }
}

# Sorted list of active exporter flags. The CLIs + tests/testinfra parametrize over it so a
# disabled exporter is skipped (not failed).
output "enabled_flags" {
  description = "Sorted list of enabled exporter feature flags (the active feature set)."
  value       = local.enabled_flags
}

# Browser URLs for `just open centralized_dns [--full]`. core = the AdGuard Home UI; all folds
# in every ENABLED /metrics endpoint (each gated on the same enable_* flag as its install).
locals {
  _ip = multipass_instance.server.ipv4

  web_urls_core = [
    "http://${local._ip}:${var.adguard_web_port}", # AdGuard Home UI
  ]

  web_urls_metrics_candidates = [
    { url = "http://${local._ip}:9100/metrics", on = var.enable_node_exporter },
    { url = "http://${local._ip}:9618/metrics", on = var.enable_adguard_exporter },
    { url = "http://${local._ip}:9167/metrics", on = var.enable_unbound_exporter },
    { url = "http://${local._ip}:9256/metrics", on = var.enable_process_exporter },
    { url = "http://${local._ip}:9558/metrics", on = var.enable_systemd_exporter },
  ]
  web_urls_metrics = [for c in local.web_urls_metrics_candidates : c.url if c.on]
}

output "web_urls" {
  description = "Browser URLs. core = AdGuard Home UI; all = core + enabled /metrics endpoints. Consumed by `just open <cluster> [--full]`."
  value = {
    core = local.web_urls_core
    all  = concat(local.web_urls_core, local.web_urls_metrics)
  }
}
