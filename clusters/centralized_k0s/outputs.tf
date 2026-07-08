# Consumed by tests/testinfra/conftest.py to build SSH testinfra hosts. Dynamic count-gated map:
# controller-1..N, worker-1..M, and haproxy only in HA mode (mirrors centralized_netbox's agent[0]).
output "hosts" {
  description = "Map of role -> {name, ipv4} for every VM in the cluster (haproxy present only when k0s_control_plane_count > 1)."
  value = merge(
    { for i, c in multipass_instance.controller : "controller-${i + 1}" => { name = c.name, ipv4 = c.ipv4 } },
    { for i, w in multipass_instance.worker : "worker-${i + 1}" => { name = w.name, ipv4 = w.ipv4 } },
    local.ha_mode ? { haproxy = { name = multipass_instance.haproxy[0].name, ipv4 = multipass_instance.haproxy[0].ipv4 } } : {},
  )
}

# Stable k0s API endpoint hostname (spec.api.externalAddress). Resolves to the HAProxy IP in HA
# mode / controller-1 in single mode via dns_records below.
output "k0s_api_endpoint" {
  description = "Stable k0s API endpoint hostname (k0s-api.<domain>). Set as spec.api.externalAddress so backup/restore survives DHCP IP churn."
  value       = local.k0s_api_host
}

output "k0s_api_ipv4" {
  description = "IPv4 the k0s API endpoint resolves to: the HAProxy VM in HA mode, controller-1 in single mode."
  value       = local.ha_mode ? multipass_instance.haproxy[0].ipv4 : multipass_instance.controller[0].ipv4
}

# hostname -> IP A-records for the fleet resolver. Includes the stable k0s-api.<domain> endpoint
# (HAProxy IP in HA mode / controller-1 in single mode). Consumed by `just set-dns`.
output "dns_records" {
  description = "hostname -> ipv4 A-records to register in centralized_dns AdGuard. Consumed by `just set-dns`. Includes k0s-api.<domain>."
  value = {
    (local.k0s_api_host) = local.ha_mode ? multipass_instance.haproxy[0].ipv4 : multipass_instance.controller[0].ipv4
  }
}

# Browser URLs for `just open centralized_k0s [--full]`. core = human dashboards (Netdata per node,
# when enabled); all = core + enabled /metrics endpoints, incl. HAProxy :8405/metrics in HA mode.
locals {
  _controller_ips = multipass_instance.controller[*].ipv4
  _worker_ips     = multipass_instance.worker[*].ipv4
  _all_node_ips   = concat(local._controller_ips, local._worker_ips)

  web_urls_core = var.enable_netdata ? [for ip in local._all_node_ips : "http://${ip}:19999"] : []

  # Node exporters on every node (:9100), plus HAProxy's native exporter (:8405) in HA mode.
  web_urls_metrics = concat(
    [for ip in local._all_node_ips : "http://${ip}:9100/metrics"],
    local.ha_mode ? ["http://${multipass_instance.haproxy[0].ipv4}:8405/metrics"] : [],
  )
}

output "web_urls" {
  description = "Browser URLs. core = human dashboards (Netdata); all = core + enabled /metrics endpoints (HAProxy :8405 in HA). Consumed by `just open <cluster> [--full]`."
  value = {
    core = local.web_urls_core
    all  = concat(local.web_urls_core, local.web_urls_metrics)
  }
}

# Opt-in feature flags beyond the base cluster. tests/testinfra reads this so live suites are
# *skipped* (not failed) when a feature is off — mirrors centralized_logging's enabled_features.
output "enabled_features" {
  description = "Opt-in feature flags: { ha, cilium, netdata }."
  value = {
    ha      = local.ha_mode
    cilium  = var.enable_cilium
    netdata = var.enable_netdata
  }
}

# True when this cluster is wired as a cross-cluster log-shipper (Vector -> logging/OpenObserve).
# Consumed by tests/testinfra as a skip-guard for the log-shipping enrichment assertions.
output "cross_cluster_enabled" {
  description = "True when log_shipping_target or openobserve_endpoint is set (Vector ships cross-cluster). Skip-guard for the live log-shipping suite."
  value       = var.log_shipping_target != "" || var.openobserve_endpoint != ""
}

output "shell_hints" {
  description = "Handy commands to poke at the cluster."
  value = join("\n", [
    "just ssh centralized_k0s controller-1",
    "ssh ubuntu@${length(local._controller_ips) > 0 ? local._controller_ips[0] : "<controller-1-ip>"} sudo k0s status",
    "ssh ubuntu@${length(local._controller_ips) > 0 ? local._controller_ips[0] : "<controller-1-ip>"} kubectl get nodes",
  ])
}
