output "controller_ipv4" {
  description = "IPv4 address of the controller (syslog-ng collector) VM."
  value       = multipass_instance.controller.ipv4
}

output "usg_ipv4" {
  description = "IPv4 address of the USG (rsyslog forwarder) VM."
  value       = multipass_instance.usg.ipv4
}

# Consumed by tests/testinfra/conftest.py to build SSH testinfra hosts.
output "hosts" {
  description = "Map of role -> {name, ipv4} for every VM in the cluster."
  value = {
    controller = { name = local.controller_name, ipv4 = multipass_instance.controller.ipv4 }
    usg        = { name = local.usg_name, ipv4 = multipass_instance.usg.ipv4 }
  }
}

# Service hostname -> IP A-record for the fleet resolver. This is a logging stand-in (the
# controller VM runs syslog-ng, not a real UniFi controller UI), but the record is registered
# for uniformity so `unifi.<domain>` resolves to that VM. `just set-dns` registers it in AdGuard.
output "dns_records" {
  description = "hostname -> ipv4 A-records to register in centralized_dns AdGuard. Consumed by `just set-dns`."
  value = {
    "unifi.${var.domain}" = multipass_instance.controller.ipv4
  }
}

output "version_mode" {
  description = "Fidelity mode in effect: 'exact' (period Debian packages in containers) or 'modern' (Ubuntu-stock on the bare VM)."
  value       = var.version_mode
}

# The exact daemon versions this cluster reproduces. tests/testinfra asserts the RUNNING versions
# (`syslog-ng --version` / `rsyslogd -version`) contain these upstream numbers.
output "versions" {
  description = "Target daemon versions: the exact Debian packages the appliances run."
  value = {
    syslog_ng = var.syslogng_deb_version # UCK Gen2 (Debian bullseye)
    rsyslog   = var.rsyslog_deb_version  # USG      (Debian wheezy)
  }
}

# Sorted list of active exporters. tests/testinfra parametrizes over this so a disabled exporter
# is skipped (not failed) in the live suite.
output "enabled_exporters" {
  description = "Sorted list of enabled exporter flags (node, syslogng)."
  value       = local.enabled_exporters
}

# Whether the docker operator TUIs (wharf/oxker/dive) are installed. Only true when both the
# flag is on AND version_mode is 'exact' (docker exists only in exact mode). conftest reads this
# so the live suite skips (not fails) when off.
output "docker_tools_enabled" {
  description = "Whether the docker TUI/inspection tools (wharf, oxker, dive) are installed (enable_docker_tools && exact mode)."
  value       = var.enable_docker_tools && local.exact
}

# Discovery map for a future centralized_monitoring scrape: role -> {ip, exporters{name=port}}.
# All listeners bind 0.0.0.0, so these <ip>:<port> targets are scrapable cross-VM/cross-cluster.
output "metrics_targets" {
  description = "Per-role exporter endpoints for a future Prometheus to scrape."
  value = {
    controller = {
      ip        = multipass_instance.controller.ipv4
      exporters = merge({ node = 9100 }, var.enable_syslogng_exporter ? { syslog_ng = 9577 } : {})
    }
    usg = {
      ip        = multipass_instance.usg.ipv4
      exporters = { node = 9100 }
    }
  }
}

# Browser URLs for `just open centralized_unifi [--full]`. There are no human dashboards in this
# cluster (it's a log pipeline), so `core` is empty and `all` folds in the enabled /metrics endpoints.
locals {
  web_urls_metrics_candidates = [
    { url = "http://${multipass_instance.controller.ipv4}:9100/metrics", on = var.enable_node_exporter },
    { url = "http://${multipass_instance.controller.ipv4}:9577/metrics", on = var.enable_syslogng_exporter },
    { url = "http://${multipass_instance.usg.ipv4}:9100/metrics", on = var.enable_node_exporter },
  ]
  web_urls_metrics = [for c in local.web_urls_metrics_candidates : c.url if c.on]
}

output "web_urls" {
  description = "Browser URLs. core = human dashboards (none here); all = the enabled /metrics endpoints. Consumed by `just open <cluster> [--full]`."
  value = {
    core = []
    all  = local.web_urls_metrics
  }
}

output "shell_hints" {
  description = "Handy commands to poke at the cluster (run after `just ssh centralized_unifi <role>`)."
  value = join("\n", [
    "just ssh centralized_unifi controller   # then: sudo docker exec unifi-syslog-ng syslog-ng --version | head -1   (-> 3.28.1)",
    "just ssh centralized_unifi usg           # then: sudo docker exec unifi-rsyslog rsyslogd -version | head -1        (-> 5.8.11)",
    "just ssh centralized_unifi controller   # then: sudo find /var/log/remote -type f",
    "just ssh centralized_unifi controller   # then: curl -s localhost:9577/metrics | grep -c syslog_ng_",
  ])
}
