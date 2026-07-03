# Layer 0/1 hermetic test — cross-cluster telemetry wiring (specs/cross-cluster.md).
# mock_provider means no Multipass is touched; command = plan asserts on rendered cloud-init.

mock_provider "multipass" {}

# File-level defaults pin every opt-in var to its OFF value so the "*_off_by_default" runs assert
# true default behavior REGARDLESS of any *.auto.tfvars OpenTofu auto-loads from the cluster dir
# (ca-material.auto.tfvars from scripts/init_ca.py, or a leftover .cross-cluster.auto.tfvars.json
# from a prior `just up-connected`). The "*_on_*" runs override these at the run level (higher
# precedence). Without this, generating the pinned root or a stale cross-cluster file breaks
# `just check`. See specs/internal-ca.md.
variables {
  ssh_pubkey           = "ssh-ed25519 AAAATESTKEY centralized-pki-tests"
  log_shipping_target  = ""
  openobserve_endpoint = ""
  dns_server           = ""
  internal_ca_cert     = ""
  root_ca_cert         = ""
  intermediate_ca_cert = ""
  intermediate_ca_key  = ""
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

# --- default: fleet-wide CA trust off -> no trust block rendered -------------
run "internal_ca_off_by_default" {
  command = plan

  assert {
    condition     = !strcontains(local_file.ca_ci.content, "internal-root-ca.crt")
    error_message = "with internal_ca_cert unset, ca cloud-init must NOT render the trust block"
  }
  assert {
    condition     = !strcontains(local_file.services_ci.content, "internal-root-ca.crt")
    error_message = "with internal_ca_cert unset, services cloud-init must NOT render the trust block"
  }
}

# --- fleet-wide CA trust on: root PEM dropped + update-ca-certificates run ----
run "internal_ca_on_renders_trust" {
  command = plan

  variables {
    internal_ca_cert = "-----BEGIN CERTIFICATE-----\nMIITESTROOTCA\n-----END CERTIFICATE-----"
  }

  assert {
    condition     = strcontains(local_file.ca_ci.content, "/usr/local/share/ca-certificates/internal-root-ca.crt")
    error_message = "ca cloud-init must drop the internal root CA when internal_ca_cert is set"
  }
  assert {
    condition     = strcontains(local_file.ca_ci.content, "update-ca-certificates")
    error_message = "ca cloud-init must run update-ca-certificates when internal_ca_cert is set"
  }
  assert {
    condition     = strcontains(local_file.services_ci.content, "/usr/local/share/ca-certificates/internal-root-ca.crt")
    error_message = "services cloud-init must drop the internal root CA when internal_ca_cert is set"
  }
  assert {
    condition     = strcontains(local_file.services_ci.content, "MIITESTROOTCA")
    error_message = "services trust block must carry the injected root CA PEM"
  }
}

# --- default: root NOT pinned -> step-ca self-inits (no pin runcmd) ----------
run "pin_ca_off_by_default" {
  command = plan

  assert {
    condition     = !strcontains(local_file.ca_ci.content, "/opt/pki/pinned/root_ca.crt")
    error_message = "with no pinned material, ca cloud-init must NOT render the pin block (ephemeral self-init)"
  }
}

# --- pinned root: material dropped + swapped into step-ca after init ----------
run "pin_ca_on_renders" {
  command = plan

  variables {
    root_ca_cert         = "-----BEGIN CERTIFICATE-----\nMIIPINNEDROOT\n-----END CERTIFICATE-----"
    intermediate_ca_cert = "-----BEGIN CERTIFICATE-----\nMIIPINNEDINT\n-----END CERTIFICATE-----"
    intermediate_ca_key  = "-----BEGIN EC PRIVATE KEY-----\nPINNEDKEY\n-----END EC PRIVATE KEY-----"
  }

  assert {
    condition     = strcontains(local_file.ca_ci.content, "/opt/pki/pinned/root_ca.crt")
    error_message = "ca cloud-init must drop the pinned root when the material is set"
  }
  assert {
    condition     = strcontains(local_file.ca_ci.content, "docker cp /opt/pki/pinned/intermediate_ca_key step-ca:/home/step/secrets/intermediate_ca_key")
    error_message = "ca cloud-init must swap the pinned intermediate key into step-ca after init"
  }
  assert {
    condition     = strcontains(local_file.ca_ci.content, "MIIPINNEDROOT")
    error_message = "pinned root file must carry the injected root PEM"
  }
}
