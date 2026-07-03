# Layer 0/1 hermetic test — cross-cluster telemetry (specs/cross-cluster.md).
# Asserts that extra_scrape_targets render into prometheus.yml as static-config jobs (PULL),
# and that the hub self-ships its own OS logs to centralized_logging when log_shipping_target
# is set (PUSH — the monitoring hub as a log-shipper, mirroring the consumer clusters).

mock_provider "multipass" {
  mock_resource "multipass_instance" {
    defaults = {
      ipv4 = "10.99.99.99"
    }
  }
}

variables {
  ssh_pubkey = "ssh-ed25519 AAAATESTKEY centralized-monitoring-tests"
}

# --- default: no cross-cluster jobs -----------------------------------------
run "no_extra_targets_by_default" {
  command = plan

  assert {
    condition     = !strcontains(local_file.server_ci.content, "cross-cluster:")
    error_message = "with extra_scrape_targets empty, prometheus.yml must not gain cross-cluster jobs"
  }
}

# --- with targets: one job per entry, pointing at ip:port -------------------
run "extra_targets_render_jobs" {
  command = plan

  variables {
    extra_scrape_targets = [
      { job = "centralized-pki-ca", ip = "10.20.0.5" },
      { job = "centralized-pki-services", ip = "10.20.0.6", port = 9256 },
    ]
  }

  assert {
    condition     = strcontains(local_file.server_ci.content, "job_name: centralized-pki-ca")
    error_message = "prometheus.yml must contain a job for each cross-cluster target"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "\"10.20.0.5:9100\"")
    error_message = "cross-cluster target must default to port 9100"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "\"10.20.0.6:9256\"")
    error_message = "cross-cluster target must honor an explicit port"
  }
}

# --- default: hub does NOT ship its own logs --------------------------------
run "no_log_shipping_by_default" {
  command = plan

  assert {
    condition     = !strcontains(local_file.server_ci.content, "d_central")
    error_message = "with log_shipping_target unset, server cloud-init must NOT render the syslog client destination"
  }
  assert {
    condition     = !strcontains(local_file.server_ci.content, "/etc/syslog-ng/conf.d/10-ship.conf")
    error_message = "with log_shipping_target unset, server cloud-init must NOT drop the syslog shipper config"
  }
}

# --- log shipping on: hub renders the syslog client drop-in to the collector -
run "hub_ships_its_own_logs" {
  command = plan

  variables {
    log_shipping_target = "10.9.9.5:5514"
  }

  assert {
    condition     = strcontains(local_file.server_ci.content, "d_central")
    error_message = "server cloud-init must render the syslog-ng d_central destination when shipping"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "\"10.9.9.5\"")
    error_message = "server syslog client must point at the injected collector IP"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "port(5514)")
    error_message = "server syslog client must use the injected collector port"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "/etc/syslog-ng/conf.d/10-ship.conf")
    error_message = "server cloud-init must drop the syslog shipper config when shipping"
  }
}

# --- default: no cross-cluster DNS drop-in ----------------------------------
run "dns_off_by_default" {
  command = plan

  assert {
    condition     = !strcontains(local_file.server_ci.content, "resolved.conf.d/99-centralized-dns.conf")
    error_message = "with dns_server unset, server cloud-init must NOT render the systemd-resolved DNS drop-in"
  }
  assert {
    condition     = !strcontains(local_file.k0s_ci.content, "resolved.conf.d/99-centralized-dns.conf")
    error_message = "with dns_server unset, k0s cloud-init must NOT render the systemd-resolved DNS drop-in"
  }
}

# --- DNS on: every VM points systemd-resolved at the centralized_dns hub -----
run "dns_on_renders_resolved_conf" {
  command = plan

  variables {
    dns_server = "10.7.7.7"
  }

  assert {
    condition     = strcontains(local_file.server_ci.content, "99-centralized-dns.conf")
    error_message = "server cloud-init must drop the systemd-resolved DNS drop-in when dns_server is set"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "DNS=10.7.7.7")
    error_message = "server DNS drop-in must point at the injected centralized_dns IP"
  }
  assert {
    condition     = strcontains(local_file.k0s_ci.content, "99-centralized-dns.conf")
    error_message = "k0s cloud-init must drop the systemd-resolved DNS drop-in when dns_server is set"
  }
  assert {
    condition     = strcontains(local_file.k0s_ci.content, "DNS=10.7.7.7")
    error_message = "k0s DNS drop-in must point at the injected centralized_dns IP"
  }
}

# --- default: no fleet-wide internal-CA trust -------------------------------
run "internal_ca_off_by_default" {
  command = plan

  assert {
    condition     = !strcontains(local_file.server_ci.content, "internal-root-ca.crt")
    error_message = "with internal_ca_cert unset, server cloud-init must NOT drop the internal root CA"
  }
  assert {
    condition     = !strcontains(local_file.k0s_ci.content, "internal-root-ca.crt")
    error_message = "with internal_ca_cert unset, k0s cloud-init must NOT drop the internal root CA"
  }
}

# --- internal CA on: every VM installs the root into the OS trust store ------
run "internal_ca_on_renders_trust" {
  command = plan

  variables {
    internal_ca_cert = "-----BEGIN CERTIFICATE-----\nMIITESTROOTCA\n-----END CERTIFICATE-----"
  }

  assert {
    condition     = strcontains(local_file.server_ci.content, "/usr/local/share/ca-certificates/internal-root-ca.crt")
    error_message = "server cloud-init must drop the internal root CA into the OS trust store when internal_ca_cert is set"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "update-ca-certificates")
    error_message = "server cloud-init must run update-ca-certificates when internal_ca_cert is set"
  }
  assert {
    condition     = strcontains(local_file.k0s_ci.content, "/usr/local/share/ca-certificates/internal-root-ca.crt")
    error_message = "k0s cloud-init must drop the internal root CA into the OS trust store when internal_ca_cert is set"
  }
  assert {
    condition     = strcontains(local_file.k0s_ci.content, "update-ca-certificates")
    error_message = "k0s cloud-init must run update-ca-certificates when internal_ca_cert is set"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "MIITESTROOTCA")
    error_message = "server cloud-init must embed the injected internal root CA PEM"
  }
}
