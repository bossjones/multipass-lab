# Layer 0/1 hermetic test — runs with `tofu test -test-directory=tests/tofu`.
# mock_provider means no Multipass is touched; command = plan asserts on rendered values.

mock_provider "multipass" {}

variables {
  # Provide an inline key so the test never depends on a real ~/.ssh file.
  ssh_pubkey = "ssh-ed25519 AAAATESTKEY centralized-pki-tests"
}

run "sizing_image_names_and_ca_render" {
  command = plan

  # --- sizing -------------------------------------------------------------
  assert {
    condition     = multipass_instance.ca.cpus == 1
    error_message = "ca cpus should be 1"
  }
  assert {
    condition     = multipass_instance.ca.memory == "1G"
    error_message = "ca memory should be 1G"
  }
  assert {
    condition     = multipass_instance.services.memory == "4G"
    error_message = "services memory should be 4G"
  }

  # --- image + names ------------------------------------------------------
  assert {
    condition     = multipass_instance.ca.image == "24.04"
    error_message = "image should be 24.04"
  }
  assert {
    condition     = multipass_instance.ca.name == "centralized-pki-ca"
    error_message = "ca name should carry the name_prefix"
  }
  assert {
    condition     = multipass_instance.services.name == "centralized-pki-services"
    error_message = "services name should carry the name_prefix"
  }

  # --- ca cloud-init carries step-ca + ACME provisioner + the SSH key -----
  assert {
    condition     = strcontains(local_file.ca_ci.content, "smallstep/step-ca")
    error_message = "ca cloud-init must run the smallstep/step-ca image"
  }
  assert {
    condition     = strcontains(local_file.ca_ci.content, "DOCKER_STEPCA_INIT_ACME=true")
    error_message = "ca cloud-init must enable the step-ca ACME provisioner"
  }
  assert {
    condition     = strcontains(local_file.ca_ci.content, "ssh-ed25519 AAAATESTKEY")
    error_message = "ca cloud-init must inject the SSH public key"
  }
}

run "services_stack_renders" {
  command = plan

  # All three services composed.
  assert {
    condition     = strcontains(local_file.services_ci.content, "traefik:v3.1")
    error_message = "services cloud-init must compose Traefik"
  }
  assert {
    condition     = strcontains(local_file.services_ci.content, "authelia/authelia")
    error_message = "services cloud-init must compose Authelia"
  }
  assert {
    condition     = strcontains(local_file.services_ci.content, "vaultwarden/server")
    error_message = "services cloud-init must compose Vaultwarden"
  }

  # Default mode issues Traefik's cert directly from step-ca's JWK provisioner (no ACME challenge).
  assert {
    condition     = strcontains(local_file.services_ci.content, "step ca certificate")
    error_message = "services cloud-init must issue Traefik's cert from step-ca in default mode"
  }
  assert {
    condition     = strcontains(local_file.services_ci.content, "--provisioner admin")
    error_message = "cert issuance must use the JWK provisioner 'admin'"
  }
  # Traefik serves that cert as its default certificate.
  assert {
    condition     = strcontains(local_file.services_ci.content, "defaultCertificate") && strcontains(local_file.services_ci.content, "/etc/traefik/certs/services.crt")
    error_message = "Traefik must serve the step-ca-issued cert as its defaultCertificate"
  }
  # Routing is via the file provider (no docker provider / socket), reaching apps by container name.
  assert {
    condition     = strcontains(local_file.services_ci.content, "Host(`auth.lab.theblacktonystark.com`)") && strcontains(local_file.services_ci.content, "http://authelia:9091")
    error_message = "Traefik must route auth.<domain> to the Authelia container via the file provider"
  }
  assert {
    condition     = strcontains(local_file.services_ci.content, "http://vaultwarden:80")
    error_message = "Traefik must route warden.<domain> to the Vaultwarden container via the file provider"
  }
  # The services VM fetches + trusts step-ca's root.
  assert {
    condition     = strcontains(local_file.services_ci.content, "roots.pem") && strcontains(local_file.services_ci.content, "update-ca-certificates")
    error_message = "services cloud-init must fetch step-ca's root and install it into the trust store"
  }
}

run "letsencrypt_off_by_default" {
  command = plan

  assert {
    condition     = !strcontains(local_file.services_ci.content, "acme-staging-v02.api.letsencrypt.org")
    error_message = "LE staging must be absent by default (enable_letsencrypt_staging=false)"
  }
  assert {
    condition     = !strcontains(local_file.services_ci.content, "GODADDY_API_KEY")
    error_message = "GoDaddy creds must not render when LE staging is off"
  }
  assert {
    condition     = strcontains(local_file.services_ci.content, "defaultCertificate")
    error_message = "default mode must serve the step-ca-issued cert as the default certificate"
  }
}

run "letsencrypt_on_renders_staging_block" {
  command = plan

  variables {
    enable_letsencrypt_staging = true
    godaddy_api_key            = "test-key"
    godaddy_api_secret         = "test-secret"
  }

  assert {
    condition     = strcontains(local_file.services_ci.content, "acme-staging-v02.api.letsencrypt.org")
    error_message = "LE staging on must render the staging caServer"
  }
  assert {
    condition     = strcontains(local_file.services_ci.content, "provider: godaddy")
    error_message = "LE staging on must render the GoDaddy DNS-01 challenge"
  }
  assert {
    condition     = strcontains(local_file.services_ci.content, "GODADDY_API_KEY=test-key")
    error_message = "LE staging on must pass the GoDaddy API key to Traefik"
  }
  # The wildcard auto-generated cert appears only in staging mode.
  assert {
    condition     = strcontains(local_file.services_ci.content, "defaultGeneratedCert") && strcontains(local_file.services_ci.content, "*.lab.theblacktonystark.com")
    error_message = "LE staging on must auto-generate a wildcard default cert"
  }
  # Direct step-ca issuance is NOT used in staging mode (Traefik uses LE ACME instead).
  assert {
    condition     = !strcontains(local_file.services_ci.content, "step ca certificate")
    error_message = "staging mode must not run the step-ca direct issuance"
  }
}

# --- time sync: every VM pins UTC + systemd-timesyncd (unconditional) --------

run "ntp_timezone_render" {
  command = plan

  assert {
    condition = alltrue([for c in [
      local_file.ca_ci.content, local_file.services_ci.content,
    ] : strcontains(c, "timezone: Etc/UTC")])
    error_message = "every VM cloud-init must pin timezone: Etc/UTC"
  }
  assert {
    condition = alltrue([for c in [
      local_file.ca_ci.content, local_file.services_ci.content,
    ] : strcontains(c, "ntp_client: systemd-timesyncd")])
    error_message = "every VM cloud-init must set the NTP client to systemd-timesyncd"
  }
  assert {
    condition = alltrue([for c in [
      local_file.ca_ci.content, local_file.services_ci.content,
    ] : strcontains(c, "timedatectl set-timezone Etc/UTC")])
    error_message = "every VM cloud-init runcmd must enforce timezone Etc/UTC"
  }
  # The injected sub-configs must keep the cloud-init valid YAML.
  assert {
    condition = alltrue([for c in [
      local_file.ca_ci.content, local_file.services_ci.content,
    ] : can(yamldecode(c))])
    error_message = "rendered cloud-init must stay valid YAML"
  }
}

run "node_exporter_flag_toggles_install" {
  command = plan

  # default on -> installed on both VMs.
  assert {
    condition     = strcontains(local_file.ca_ci.content, "node_exporter-1.8.2") && strcontains(local_file.services_ci.content, "node_exporter-1.8.2")
    error_message = "node_exporter must install on both VMs by default"
  }
  # process-exporter (:9256, v0.8.7 + perf flags) + systemd_exporter (:9558, curated) on both VMs.
  assert {
    condition     = strcontains(local_file.ca_ci.content, "process-exporter-0.8.7") && strcontains(local_file.services_ci.content, "process-exporter-0.8.7")
    error_message = "process-exporter v0.8.7 must install on both VMs by default"
  }
  assert {
    condition     = strcontains(local_file.ca_ci.content, "-threads=false -gather-smaps=false -remove-empty-groups") && strcontains(local_file.services_ci.content, "-threads=false -gather-smaps=false -remove-empty-groups")
    error_message = "process-exporter must run with the low-cardinality perf flags on both VMs"
  }
  assert {
    condition     = strcontains(local_file.ca_ci.content, "--web.listen-address=:9558") && strcontains(local_file.services_ci.content, "--systemd.collector.unit-include=")
    error_message = "systemd_exporter (:9558, curated unit-include) must install on both VMs"
  }
}

run "exporters_off_omit_install" {
  command = plan

  variables {
    enable_process_exporter = false
    enable_systemd_exporter = false
  }

  assert {
    condition     = !strcontains(local_file.ca_ci.content, "process-exporter") && !strcontains(local_file.services_ci.content, "process-exporter")
    error_message = "disabled process-exporter must not render on either VM"
  }
  assert {
    condition     = !strcontains(local_file.ca_ci.content, "systemd_exporter") && !strcontains(local_file.services_ci.content, "systemd_exporter")
    error_message = "disabled systemd_exporter must not render on either VM"
  }
}

run "node_exporter_off_omits_install" {
  command = plan

  variables {
    enable_node_exporter = false
  }

  assert {
    condition     = !strcontains(local_file.ca_ci.content, "node_exporter-1.8.2")
    error_message = "disabled node_exporter must not render on the ca VM"
  }
}

run "web_urls_core_and_flag_aware" {
  command = plan

  # core = auth + warden + traefik dashboard + step-ca health.
  assert {
    condition     = length(output.web_urls.core) == 4
    error_message = "web_urls.core must list auth/warden/traefik/step-ca"
  }
  assert {
    condition     = length(output.web_urls.all) > length(output.web_urls.core)
    error_message = "web_urls.all must add the /metrics endpoints on top of core (node_exporter on)"
  }
  # enabled_flags carries node_exporter by default and not LE staging.
  assert {
    condition     = contains(output.enabled_flags, "enable_node_exporter") && !contains(output.enabled_flags, "enable_letsencrypt_staging")
    error_message = "enabled_flags must reflect the default feature set"
  }
}

# --- Docker operator tooling (wharf/oxker/dive) — default ON on both docker VMs -------

run "docker_tools_render_by_default" {
  command = plan

  # Both VMs run docker, so both carry the installer.
  assert {
    condition     = strcontains(local_file.ca_ci.content, "install-docker-tools.sh") && strcontains(local_file.services_ci.content, "install-docker-tools.sh")
    error_message = "both the ca and services VMs must install the docker operator TUIs by default"
  }
  assert {
    condition = alltrue([for m in [
      "idesyatov/wharf", "mrjackwills/oxker", "wagoodman/dive",
      "WHARF_VERSION=\"0.9.1\"", "OXKER_VERSION=\"0.13.2\"", "DIVE_VERSION=\"0.13.1\"",
    ] : strcontains(local_file.services_ci.content, m)])
    error_message = "services cloud-init must reference the pinned wharf/oxker/dive releases"
  }
  assert {
    condition     = output.docker_tools_enabled == true
    error_message = "docker_tools_enabled output must report true by default"
  }
  assert {
    condition     = can(yamldecode(local_file.ca_ci.content)) && can(yamldecode(local_file.services_ci.content))
    error_message = "both cloud-inits must stay valid YAML after adding the docker-tools installer"
  }
}

run "docker_tools_absent_when_disabled" {
  command = plan

  variables {
    enable_docker_tools = false
  }

  assert {
    condition     = !strcontains(local_file.ca_ci.content, "install-docker-tools.sh") && !strcontains(local_file.services_ci.content, "install-docker-tools.sh")
    error_message = "disabled enable_docker_tools must omit the installer from both VMs"
  }
}
