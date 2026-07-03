output "ca_ipv4" {
  description = "IPv4 address of the step-ca VM."
  value       = multipass_instance.ca.ipv4
}

output "services_ipv4" {
  description = "IPv4 address of the Traefik/Authelia/Vaultwarden VM."
  value       = multipass_instance.services.ipv4
}

# Consumed by tests/testinfra/conftest.py to build SSH testinfra hosts.
output "hosts" {
  description = "Map of role -> {name, ipv4} for every VM in the cluster."
  value = {
    ca       = { name = local.ca_name, ipv4 = multipass_instance.ca.ipv4 }
    services = { name = local.services_name, ipv4 = multipass_instance.services.ipv4 }
  }
}

output "domain" {
  description = "DNS suffix for internal services (ca./auth./vault. live under this)."
  value       = var.domain
}

output "acme_directory_url" {
  description = "step-ca ACME directory URL Traefik uses in the default (internal-ACME) mode."
  value       = local.acme_directory_url
}

# Sorted list of active feature flags. The CLIs read this (tls_cli picks the expected root from
# enable_letsencrypt_staging) and tests/testinfra parametrizes over it so a disabled feature is
# skipped (not failed).
output "enabled_flags" {
  description = "Sorted list of enabled feature flags (the active feature set)."
  value       = local.enabled_flags
}

output "shell_hints" {
  description = "Handy commands to poke at the cluster."
  value = join("\n", [
    "multipass shell ${local.ca_name}",
    "curl -k https://${multipass_instance.ca.ipv4}:9000/health   # step-ca health",
    "multipass exec ${local.ca_name} -- docker exec centralized-pki-step-ca step certificate fingerprint /home/step/certs/root_ca.crt",
    "open https://auth.${var.domain}   # Authelia (needs ca.<domain>/auth.<domain> -> ${multipass_instance.services.ipv4} in your resolver)",
  ])
}

# Browser URLs for `just open centralized_pki [--full]`. core = the human-facing services on the
# services VM + the CA health endpoint (always present); all folds in every enabled /metrics
# endpoint, each gated on the same enable_* flag that governs its install in cloud-init.
locals {
  _svc_ip = multipass_instance.services.ipv4
  _ca_ip  = multipass_instance.ca.ipv4

  web_urls_core = [
    "https://auth.${var.domain}",          # Authelia (forward-auth SSO)
    "https://vault.${var.domain}",         # Vaultwarden
    "http://${local._svc_ip}:8080",        # Traefik dashboard
    "https://${local._ca_ip}:9000/health", # step-ca health
  ]

  web_urls_metrics_candidates = [
    { url = "http://${local._ca_ip}:9100/metrics", on = var.enable_node_exporter },
    { url = "http://${local._ca_ip}:9256/metrics", on = var.enable_process_exporter },
    { url = "http://${local._ca_ip}:9558/metrics", on = var.enable_systemd_exporter },
    { url = "http://${local._svc_ip}:9100/metrics", on = var.enable_node_exporter },
    { url = "http://${local._svc_ip}:9256/metrics", on = var.enable_process_exporter },
    { url = "http://${local._svc_ip}:9558/metrics", on = var.enable_systemd_exporter },
  ]
  web_urls_metrics = [for c in local.web_urls_metrics_candidates : c.url if c.on]
}

output "web_urls" {
  description = "Browser URLs. core = human-facing services; all = core + enabled /metrics endpoints. Consumed by `just open <cluster> [--full]`."
  value = {
    core = local.web_urls_core
    all  = concat(local.web_urls_core, local.web_urls_metrics)
  }
}
