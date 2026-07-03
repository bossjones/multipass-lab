# Layer 0/1 hermetic test — cross-cluster telemetry wiring (specs/cross-cluster.md).
# mock_provider means no Multipass is touched; command = plan asserts on rendered cloud-init.

mock_provider "multipass" {}

variables {
  ssh_pubkey = "ssh-ed25519 AAAATESTKEY centralized-pki-tests"
}

# --- default: cross-cluster off -> no shipping/OTLP wiring rendered ----------
run "cross_cluster_off_by_default" {
  command = plan

  assert {
    condition     = !strcontains(local_file.services_ci.content, "d_central")
    error_message = "with log_shipping_target unset, services cloud-init must NOT render the syslog client destination"
  }
  assert {
    condition     = !strcontains(local_file.ca_ci.content, "otlphttp/host")
    error_message = "with openobserve_endpoint unset, ca cloud-init must NOT render the OTLP agent"
  }
}

# --- log shipping on: syslog client drop-in renders with the collector IP ----
run "log_shipping_renders_client_conf" {
  command = plan

  variables {
    log_shipping_target = "10.9.9.5:5514"
  }

  assert {
    condition     = strcontains(local_file.services_ci.content, "d_central")
    error_message = "services cloud-init must render the syslog-ng d_central destination when shipping"
  }
  assert {
    condition     = strcontains(local_file.services_ci.content, "\"10.9.9.5\"")
    error_message = "services syslog client must point at the injected collector IP"
  }
  assert {
    condition     = strcontains(local_file.services_ci.content, "port(5514)")
    error_message = "services syslog client must use the injected collector port"
  }
  assert {
    condition     = strcontains(local_file.ca_ci.content, "/etc/syslog-ng/conf.d/10-ship.conf")
    error_message = "ca cloud-init must drop the syslog shipper config when shipping"
  }
}

# --- OTLP push on: otelcol-contrib agent renders with the OpenObserve IP -----
run "otlp_push_renders_agent_conf" {
  command = plan

  variables {
    openobserve_endpoint = "10.9.9.7:5080"
  }

  assert {
    condition     = strcontains(local_file.services_ci.content, "otlphttp/host")
    error_message = "services cloud-init must render the OTLP exporter when pushing to OpenObserve"
  }
  assert {
    condition     = strcontains(local_file.services_ci.content, "http://10.9.9.7:5080/api/default")
    error_message = "OTLP endpoint must carry the injected OpenObserve IP + org"
  }
  # Per-VM stream separation: ca -> *_ca, services -> *_services.
  assert {
    condition     = strcontains(local_file.ca_ci.content, "stream-name: centralized_pki_ca")
    error_message = "ca OTLP agent must ship to the centralized_pki_ca stream"
  }
  assert {
    condition     = strcontains(local_file.services_ci.content, "stream-name: centralized_pki_services")
    error_message = "services OTLP agent must ship to the centralized_pki_services stream"
  }
}

# --- default: cross-cluster DNS off -> no resolved.conf.d drop-in rendered ----
run "dns_off_by_default" {
  command = plan

  assert {
    condition     = !strcontains(local_file.ca_ci.content, "resolved.conf.d/99-centralized-dns.conf")
    error_message = "with dns_server unset, ca cloud-init must NOT render the systemd-resolved drop-in"
  }
  assert {
    condition     = !strcontains(local_file.services_ci.content, "resolved.conf.d/99-centralized-dns.conf")
    error_message = "with dns_server unset, services cloud-init must NOT render the systemd-resolved drop-in"
  }
}

# --- DNS on: systemd-resolved drop-in renders with the AdGuard resolver IP ----
run "dns_on_renders_resolved_conf" {
  command = plan

  variables {
    dns_server = "10.7.7.7"
  }

  assert {
    condition     = strcontains(local_file.ca_ci.content, "resolved.conf.d/99-centralized-dns.conf")
    error_message = "ca cloud-init must drop the systemd-resolved config when dns_server is set"
  }
  assert {
    condition     = strcontains(local_file.ca_ci.content, "DNS=10.7.7.7")
    error_message = "ca systemd-resolved drop-in must point at the injected AdGuard resolver IP"
  }
  assert {
    condition     = strcontains(local_file.services_ci.content, "resolved.conf.d/99-centralized-dns.conf")
    error_message = "services cloud-init must drop the systemd-resolved config when dns_server is set"
  }
  assert {
    condition     = strcontains(local_file.services_ci.content, "DNS=10.7.7.7")
    error_message = "services systemd-resolved drop-in must point at the injected AdGuard resolver IP"
  }
}
