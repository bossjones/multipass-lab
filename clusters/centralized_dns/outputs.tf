output "server_ipv4" {
  description = "IPv4 address of the DNS VM (AdGuard Home :53 + web UI, Unbound upstream). Single mode only — see dns_endpoint for the HA-aware equivalent."
  value       = local.ha ? null : multipass_instance.server[0].ipv4
}

# The stable address the FLEET should resolve against: the VIP in HA mode, the single VM's IP
# otherwise. `just up-connected`'s health-gate + every consumer cluster's dns_server wiring reads
# THIS output (not server_ipv4), so no mode-branching is needed at the call site.
output "dns_endpoint" {
  description = "IP the fleet resolves DNS against: the floating VIP in HA mode, the single server VM's IP otherwise. See specs/ha-dns.md."
  value       = local.dns_endpoint
}

# Where DNS-record pushes (`just set-dns-all`, Traefik hostname rewrites) should target: the
# ORIGIN node in HA mode (AdGuardHome-Sync then replicates to the replica), the single VM
# otherwise. Pushing at the VIP in HA mode would race the next sync cycle.
output "dns_rewrite_target" {
  description = "IP `just set-dns-all` / Traefik DNS-rewrite recipes should push to: primary's IP in HA mode (AdGuardHome-Sync replicates to secondary), the single server VM's IP otherwise."
  value       = local.dns_rewrite_target
}

output "vip_address" {
  description = "The floating VIP in HA mode; empty string in single mode."
  value       = local.ha ? var.vip_address : ""
}

# Consumed by tests/testinfra/conftest.py to build SSH testinfra hosts, and by up-connected.
output "hosts" {
  description = "Map of role -> {name, ipv4} for every VM in the cluster. {server} in single mode; {primary, secondary} in HA mode."
  value = local.ha ? {
    for role, inst in multipass_instance.node : role => { name = inst.name, ipv4 = inst.ipv4 }
    } : {
    server = { name = local.server_name, ipv4 = multipass_instance.server[0].ipv4 }
  }
}

# Service hostname -> IP A-records for the fleet resolver. `just set-dns` reads this and registers
# each as an AdGuard rewrite so these names resolve fleet-wide. Points at dns_rewrite_target (the
# origin in HA mode) so AdGuardHome-Sync — not a racing direct write — keeps secondary in sync.
output "dns_records" {
  description = "hostname -> ipv4 A-records to register in centralized_dns AdGuard. Consumed by `just set-dns`."
  value = {
    "adguard.${var.domain}" = local.dns_rewrite_target
    "dns.${var.domain}"     = local.dns_endpoint
  }
}

output "adguard_url" {
  description = "AdGuard Home web UI + /control API base URL. Points at the origin node's real IP in HA mode (never the VIP — editing config must happen on primary; see USAGE.md)."
  value       = "http://${local.dns_rewrite_target}:${var.adguard_web_port}"
}

# Routes the fleet-edge Traefik (centralized_pki) should publish for this cluster. Consumed by
# scripts/traefik_cli.py (see specs/dynamic-traefik.md).
output "reverse_proxy_routes" {
  description = "Routes the fleet-edge Traefik should publish for this cluster. Consumed by scripts/traefik_cli.py."
  value = [
    { host = "adguard", ip = local.dns_rewrite_target, port = var.adguard_web_port, scheme = "http", sso = false, k0s = false },
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

output "enabled_features" {
  description = "HA-aware feature flags, consumed by testinfra to skip HA-only live suites (mirrors centralized_k0s's enabled_features.ha)."
  value = {
    ha = local.ha
  }
}

# Browser URLs for `just open centralized_dns [--full]`. core = the AdGuard Home UI (per node in
# HA mode, plus the VIP); all folds in every ENABLED /metrics endpoint on every node.
locals {
  _urls_ip = local.ha ? [for role in ["primary", "secondary"] : multipass_instance.node[role].ipv4] : [multipass_instance.server[0].ipv4]

  web_urls_core = local.ha ? concat(
    ["http://${var.vip_address}:${var.adguard_web_port}"],
    [for ip in local._urls_ip : "http://${ip}:${var.adguard_web_port}"],
    ) : [
    "http://${local._urls_ip[0]}:${var.adguard_web_port}", # AdGuard Home UI
  ]

  web_urls_metrics_candidates = flatten([
    for ip in local._urls_ip : [
      { url = "http://${ip}:9100/metrics", on = var.enable_node_exporter },
      { url = "http://${ip}:9618/metrics", on = var.enable_adguard_exporter },
      { url = "http://${ip}:9167/metrics", on = var.enable_unbound_exporter },
      { url = "http://${ip}:9256/metrics", on = var.enable_process_exporter },
      { url = "http://${ip}:9558/metrics", on = var.enable_systemd_exporter },
    ]
  ])
  web_urls_metrics = [for c in local.web_urls_metrics_candidates : c.url if c.on]
}

output "web_urls" {
  description = "Browser URLs. core = AdGuard Home UI (+ VIP in HA mode); all = core + enabled /metrics endpoints on every node. Consumed by `just open <cluster> [--full]`."
  value = {
    core = local.web_urls_core
    all  = concat(local.web_urls_core, local.web_urls_metrics)
  }
}
