# Layer 0/1 hermetic test — cross-cluster telemetry wiring (specs/cross-cluster.md).
# mock_provider means no Multipass is touched; command = plan asserts on rendered cloud-init.

mock_provider "multipass" {}

variables {
  ssh_pubkey = "ssh-ed25519 AAAATESTKEY centralized-dns-tests"
  # Pin opt-in vars OFF so the *_off_by_default runs stay hermetic to whatever *.auto.tfvars
  # OpenTofu auto-loads from the cluster dir (a leftover .cross-cluster.auto.tfvars.json from a
  # prior `just up-connected`, or ca-material.auto.tfvars). On-runs override at the run level.
  # See specs/internal-ca.md.
  dns_server           = ""
  internal_ca_cert     = ""
  log_shipping_target  = ""
  openobserve_endpoint = ""
  # Phase 2 internal-CA TLS: `just dns-register` writes dns_rewrites into an auto.tfvars; pin it
  # empty so the off-by-default run is hermetic to a leftover file. See specs/internal-ca.md.
  dns_rewrites = []
}

# --- default: cross-cluster off -> no shipping/OTLP wiring rendered ----------
run "cross_cluster_off_by_default" {
  command = plan

  assert {
    condition     = !strcontains(local_file.server_ci.content, "d_central")
    error_message = "with log_shipping_target unset, cloud-init must NOT render the syslog client destination"
  }
  assert {
    condition     = !strcontains(local_file.server_ci.content, "otlphttp/host")
    error_message = "with openobserve_endpoint unset, cloud-init must NOT render the OTLP agent"
  }
  # The DNS VM resolves through its OWN AdGuard, not an external hub -> no external resolver drop-in.
  assert {
    condition     = !strcontains(local_file.server_ci.content, "resolved.conf.d/99-centralized-dns.conf")
    error_message = "with dns_server unset, cloud-init must NOT point at an external DNS hub"
  }
  # ...but it always frees :53 for its own AdGuard (its own resolver is repointed in runcmd).
  assert {
    condition     = strcontains(local_file.server_ci.content, "ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf")
    error_message = "the DNS VM must repoint its own resolver off the disabled stub"
  }
}

# --- log shipping on: syslog client drop-in renders with the collector IP ----
run "log_shipping_renders_client_conf" {
  command = plan

  variables {
    log_shipping_target = "10.9.9.5:5514"
  }

  assert {
    condition     = strcontains(local_file.server_ci.content, "d_central")
    error_message = "cloud-init must render the syslog-ng d_central destination when shipping"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "\"10.9.9.5\"")
    error_message = "syslog client must point at the injected collector IP"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "port(5514)")
    error_message = "syslog client must use the injected collector port"
  }
  # The hot-push artifact is materialized on disk for scp.
  assert {
    condition     = length(local_file.ship_conf) == 1
    error_message = "log shipping on must render the .rendered/10-ship.conf hot-push artifact"
  }
}

# --- OTLP push on: otelcol-contrib agent renders with the OpenObserve IP -----
run "otlp_push_renders_agent_conf" {
  command = plan

  variables {
    openobserve_endpoint = "10.9.9.7:5080"
  }

  assert {
    condition     = strcontains(local_file.server_ci.content, "otlphttp/host")
    error_message = "cloud-init must render the OTLP exporter when pushing to OpenObserve"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "http://10.9.9.7:5080/api/default")
    error_message = "OTLP endpoint must carry the injected OpenObserve IP + org"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "stream-name: centralized_dns_server")
    error_message = "OTLP agent must ship to the centralized_dns_server stream"
  }
  assert {
    condition     = length(local_file.otel_conf) == 1
    error_message = "OTLP push on must render the .rendered/otel-config.yaml hot-push artifact"
  }
}

# --- dns_server set: external resolver drop-in renders (contract symmetry) ----
run "dns_server_renders_resolved_conf" {
  command = plan

  variables {
    dns_server = "10.7.7.7"
  }

  assert {
    condition     = strcontains(local_file.server_ci.content, "resolved.conf.d/99-centralized-dns.conf")
    error_message = "dns_server set must render the external resolver drop-in"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "DNS=10.7.7.7")
    error_message = "external resolver drop-in must carry the injected DNS IP"
  }
}

# --- default: internal CA trust off -> no CA cert dropped into the trust store ----
run "internal_ca_off_by_default" {
  command = plan

  assert {
    condition     = !strcontains(local_file.server_ci.content, "internal-root-ca.crt")
    error_message = "with internal_ca_cert unset, cloud-init must NOT drop a root CA into the trust store"
  }
}

# --- internal CA set: root CA rendered into the OS trust store + update-ca-certificates ----
run "internal_ca_on_renders_trust" {
  command = plan

  variables {
    internal_ca_cert = "-----BEGIN CERTIFICATE-----\nMIITESTROOTCA\n-----END CERTIFICATE-----"
  }

  assert {
    condition     = strcontains(local_file.server_ci.content, "/usr/local/share/ca-certificates/internal-root-ca.crt")
    error_message = "internal_ca_cert set must drop the root CA into /usr/local/share/ca-certificates"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "update-ca-certificates")
    error_message = "internal_ca_cert set must run update-ca-certificates to install the trust"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "MIITESTROOTCA")
    error_message = "the rendered CA cert must carry the injected PEM body"
  }
}

# --- default: no AdGuard host rewrites (Phase 2 internal-CA TLS) -------------
run "dns_rewrites_off_by_default" {
  command = plan

  assert {
    condition     = strcontains(local_file.adguard_conf.content, "rewrites: []")
    error_message = "with dns_rewrites empty, the seeded AdGuardHome.yaml must render an empty rewrites list"
  }
}

# --- dns_rewrites on: hostnames render as AdGuard host rewrites --------------
run "dns_rewrites_render_records" {
  command = plan

  variables {
    dns_rewrites = [
      { domain = "grafana.lab.theblacktonystark.com", answer = "10.0.0.9" },
      { domain = "prometheus.lab.theblacktonystark.com", answer = "10.0.0.9" },
    ]
  }

  assert {
    condition     = strcontains(local_file.adguard_conf.content, "- domain: grafana.lab.theblacktonystark.com")
    error_message = "seeded AdGuardHome.yaml must carry a rewrite entry for each dns_rewrites domain"
  }
  assert {
    condition     = strcontains(local_file.adguard_conf.content, "answer: 10.0.0.9")
    error_message = "each rewrite must map to its injected answer IP"
  }
  # the standalone rendered file feeds `just dns-register`'s hot-push
  assert {
    condition     = strcontains(local_file.server_ci.content, "- domain: prometheus.lab.theblacktonystark.com")
    error_message = "the embedded (write_files) AdGuard seed must also carry the rewrites"
  }
}
