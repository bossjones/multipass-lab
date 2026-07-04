# Layer 0/1 hermetic test — runs with `tofu test -test-directory=tests/tofu`.
# mock_provider means no Multipass is touched; command = plan asserts on rendered values.

mock_provider "multipass" {}

variables {
  # Provide an inline key so the test never depends on a real ~/.ssh file.
  ssh_pubkey = "ssh-ed25519 AAAATESTKEY centralized-unifi-tests"
  # Pin cross-cluster opt-in vars OFF so *_off_by_default runs are hermetic to auto-loaded
  # *.auto.tfvars (e.g. a leftover .cross-cluster.auto.tfvars.json). On-runs override. See specs/internal-ca.md.
  dns_server       = ""
  internal_ca_cert = ""
  ntp_server       = ""
}

run "sizing_image_and_names" {
  command = plan

  assert {
    condition     = multipass_instance.controller.cpus == 2
    error_message = "controller cpus should be 2"
  }
  assert {
    condition     = multipass_instance.controller.memory == "2G"
    error_message = "controller memory should be 2G"
  }
  assert {
    condition     = multipass_instance.controller.disk == "20G"
    error_message = "controller disk should be 20G"
  }
  assert {
    condition     = multipass_instance.usg.memory == "2G"
    error_message = "usg memory should be 2G"
  }
  assert {
    condition     = multipass_instance.controller.image == "24.04" && multipass_instance.usg.image == "24.04"
    error_message = "both VMs should use image 24.04 (the host OS; exact daemons run in containers)"
  }
  assert {
    condition     = multipass_instance.controller.name == "centralized-unifi-controller"
    error_message = "controller name should carry the name_prefix"
  }
  assert {
    condition     = multipass_instance.usg.name == "centralized-unifi-usg"
    error_message = "usg name should carry the name_prefix"
  }
}

run "exact_mode_controller_render" {
  command = plan

  # The exact syslog-ng 3.28.1 image is built FROM the matching Debian release, pinned.
  assert {
    condition     = strcontains(local_file.controller_ci.content, "FROM debian:bullseye")
    error_message = "controller must build the syslog-ng container FROM debian:bullseye"
  }
  assert {
    condition     = strcontains(local_file.controller_ci.content, "syslog-ng-core=3.28.1-2+deb11u2")
    error_message = "controller must pin the exact bullseye syslog-ng package version"
  }
  # Collector source + file sink + the not2msg firewall markers + raised stats level for the exporter.
  assert {
    condition     = strcontains(local_file.controller_ci.content, "network(") && strcontains(local_file.controller_ci.content, "/var/log/remote")
    error_message = "controller syslog-ng config must add the network() collector source + /var/log/remote sink"
  }
  assert {
    condition     = strcontains(local_file.controller_ci.content, "[ALIEN BLOCK]")
    error_message = "controller must inline the not2msg macro (the [ALIEN BLOCK] marker)"
  }
  assert {
    condition     = strcontains(local_file.controller_ci.content, "stats_level(1)")
    error_message = "controller must raise stats_level so the legacy exporter has counters"
  }
  # The legacy-CSV exporter sidecar (works on 3.28.1) on :9577. Match the real service lines
  # (image:/telemetry.address=), not the header comments that also mention the exporter/port.
  assert {
    condition     = strcontains(local_file.controller_ci.content, "image: brandond/syslog_ng_exporter") && strcontains(local_file.controller_ci.content, "telemetry.address=:9577")
    error_message = "controller must run the syslog_ng_exporter sidecar on :9577"
  }
  assert {
    condition     = strcontains(local_file.controller_ci.content, "ssh-ed25519 AAAATESTKEY")
    error_message = "controller cloud-init must inject the SSH public key"
  }
  # container-based exact mode: Docker + binfmt safety net present.
  assert {
    condition     = strcontains(local_file.controller_ci.content, "docker.io")
    error_message = "exact-mode controller must install Docker"
  }
}

run "exact_mode_usg_render_and_ip_injection" {
  command = plan

  # The exact rsyslog 5.8.11 image FROM archived wheezy, emulated amd64, pinned.
  assert {
    condition     = strcontains(local_file.usg_ci.content, "debian/eol:wheezy")
    error_message = "usg must build the rsyslog container FROM debian/eol:wheezy"
  }
  assert {
    condition     = strcontains(local_file.usg_ci.content, "platform: linux/amd64")
    error_message = "usg container must be pinned to linux/amd64 (wheezy has no arm64 build)"
  }
  assert {
    condition     = strcontains(local_file.usg_ci.content, "archive.debian.org")
    error_message = "usg must fetch the wheezy rsyslog .deb from archive.debian.org"
  }
  assert {
    condition     = strcontains(local_file.usg_ci.content, "rsyslog_5.8.11-3+deb7u2_amd64.deb")
    error_message = "usg must fetch the exact wheezy rsyslog .deb (5.8.11-3+deb7u2) natively (apt segfaults under qemu)"
  }
  assert {
    condition     = strcontains(local_file.usg_ci.content, "dpkg-deb -x")
    error_message = "usg must extract the .deb with dpkg-deb -x (no in-container apt)"
  }
  assert {
    condition     = strcontains(local_file.usg_ci.content, "qemu-user-static")
    error_message = "usg host must install qemu-user-static for amd64 emulation"
  }
  # IP injection: the Vyatta forward targets the (mock) controller IP, NOT the appliance's hardcoded IP.
  assert {
    condition     = !strcontains(local_file.usg_ci.content, "192.168.3.16")
    error_message = "usg must NOT carry the appliance's hardcoded 192.168.3.16 forward target"
  }
  assert {
    condition     = strcontains(local_file.usg_ci.content, "local7.debug\t@")
    error_message = "usg must render the Vyatta UDP forward rule (single @ = UDP)"
  }
  # Generator on by default.
  assert {
    condition     = strcontains(local_file.usg_ci.content, "ENABLE_TRAFFIC=1")
    error_message = "usg traffic generator must be enabled by default (ENABLE_TRAFFIC=1)"
  }
}

run "disabled_flags_omit_blocks" {
  command = plan

  variables {
    enable_syslogng_exporter = false
    enable_unifi_traffic     = false
  }

  assert {
    condition     = !strcontains(local_file.controller_ci.content, "image: brandond/syslog_ng_exporter")
    error_message = "disabled syslogng exporter must not render the sidecar"
  }
  assert {
    condition     = !strcontains(local_file.controller_ci.content, "telemetry.address=:9577")
    error_message = "disabled syslogng exporter must not expose :9577"
  }
  assert {
    condition     = strcontains(local_file.usg_ci.content, "ENABLE_TRAFFIC=0")
    error_message = "disabled traffic generator must render ENABLE_TRAFFIC=0"
  }
}

run "modern_mode_uses_ubuntu_native_path" {
  command = plan

  variables {
    version_mode = "modern"
  }

  # Modern mode must NOT bring in the period Debian containers.
  assert {
    condition     = !strcontains(local_file.usg_ci.content, "debian/eol:wheezy")
    error_message = "modern mode must not render the wheezy rsyslog container"
  }
  assert {
    condition     = !strcontains(local_file.controller_ci.content, "FROM debian:bullseye")
    error_message = "modern mode must not render the bullseye syslog-ng container"
  }
  # Modern mode installs bare packages + the native textfile exporter.
  assert {
    condition     = strcontains(local_file.controller_ci.content, "syslog-ng-ctl stats prometheus")
    error_message = "modern-mode controller must use the native syslog-ng prometheus stats (textfile)"
  }
  assert {
    condition     = strcontains(local_file.usg_ci.content, "unifi-gen.service")
    error_message = "modern-mode usg must run the generator as a host systemd service"
  }
  assert {
    condition     = output.version_mode == "modern"
    error_message = "version_mode output must reflect modern"
  }
  # No docker daemon in modern mode, so the docker tools must not render there.
  assert {
    condition     = !strcontains(local_file.controller_ci.content, "install-docker-tools.sh") && !strcontains(local_file.usg_ci.content, "install-docker-tools.sh")
    error_message = "modern mode has no docker, so the docker-tools installer must be absent"
  }
  assert {
    condition     = output.docker_tools_enabled == false
    error_message = "docker_tools_enabled must be false in modern mode (docker absent)"
  }
}

# --- Docker operator tooling (wharf/oxker/dive) — default ON in exact mode only --------

run "docker_tools_render_in_exact_mode" {
  command = plan

  # Default version_mode is 'exact', so both docker VMs carry the installer.
  assert {
    condition     = strcontains(local_file.controller_ci.content, "install-docker-tools.sh") && strcontains(local_file.usg_ci.content, "install-docker-tools.sh")
    error_message = "both VMs must install the docker operator TUIs in exact mode by default"
  }
  assert {
    condition = alltrue([for m in [
      "idesyatov/wharf", "mrjackwills/oxker", "wagoodman/dive",
      "WHARF_VERSION=\"0.9.1\"", "OXKER_VERSION=\"0.13.2\"", "DIVE_VERSION=\"0.13.1\"",
    ] : strcontains(local_file.usg_ci.content, m)])
    error_message = "usg cloud-init must reference the pinned wharf/oxker/dive releases"
  }
  assert {
    condition     = output.docker_tools_enabled == true
    error_message = "docker_tools_enabled output must report true in exact mode by default"
  }
}

run "docker_tools_absent_when_disabled" {
  command = plan

  variables {
    enable_docker_tools = false
  }

  assert {
    condition     = !strcontains(local_file.controller_ci.content, "install-docker-tools.sh") && !strcontains(local_file.usg_ci.content, "install-docker-tools.sh")
    error_message = "disabled enable_docker_tools must omit the installer from both VMs"
  }
}

run "cloud_init_is_valid_yaml_and_utc" {
  command = plan

  # Both rendered cloud-inits must stay valid YAML with the spliced Dockerfiles/compose/configs.
  assert {
    condition     = can(yamldecode(local_file.controller_ci.content)) && can(yamldecode(local_file.usg_ci.content))
    error_message = "both rendered cloud-inits must be valid YAML"
  }
  # Every VM pins UTC + systemd-timesyncd and enforces it late in runcmd.
  assert {
    condition = alltrue([for c in [local_file.controller_ci.content, local_file.usg_ci.content] :
      strcontains(c, "timezone: Etc/UTC") && strcontains(c, "ntp_client: systemd-timesyncd") && strcontains(c, "timedatectl set-timezone Etc/UTC")
    ])
    error_message = "every VM cloud-init must pin UTC + systemd-timesyncd and enforce UTC in runcmd"
  }
}

# --- Cross-cluster DNS (opt-in) — off by default, wires systemd-resolved when set --------

run "dns_off_by_default" {
  command = plan

  assert {
    condition     = !strcontains(local_file.controller_ci.content, "resolved.conf.d/99-centralized-dns.conf")
    error_message = "controller must NOT render the centralized-dns drop-in when dns_server is empty"
  }
  assert {
    condition     = !strcontains(local_file.usg_ci.content, "resolved.conf.d/99-centralized-dns.conf")
    error_message = "usg must NOT render the centralized-dns drop-in when dns_server is empty"
  }
}

run "dns_on_points_resolved_at_hub" {
  command = plan

  variables {
    dns_server = "10.7.7.7"
  }

  assert {
    condition     = strcontains(local_file.controller_ci.content, "resolved.conf.d/99-centralized-dns.conf") && strcontains(local_file.controller_ci.content, "DNS=10.7.7.7")
    error_message = "controller must render the centralized-dns drop-in with DNS=10.7.7.7 when dns_server is set"
  }
  assert {
    condition     = strcontains(local_file.usg_ci.content, "resolved.conf.d/99-centralized-dns.conf") && strcontains(local_file.usg_ci.content, "DNS=10.7.7.7")
    error_message = "usg must render the centralized-dns drop-in with DNS=10.7.7.7 when dns_server is set"
  }
  # cloud-init must stay valid YAML with the spliced drop-in.
  assert {
    condition     = can(yamldecode(local_file.controller_ci.content)) && can(yamldecode(local_file.usg_ci.content))
    error_message = "both cloud-inits must remain valid YAML with the DNS drop-in spliced in"
  }
}

run "outputs_expose_versions_and_targets" {
  command = plan

  assert {
    condition     = output.versions.syslog_ng == "3.28.1-2+deb11u2" && output.versions.rsyslog == "5.8.11-3+deb7u2"
    error_message = "versions output must report the exact target Debian package versions"
  }
  assert {
    condition     = output.metrics_targets.controller.exporters.syslog_ng == 9577
    error_message = "metrics_targets must expose the controller syslog_ng exporter on 9577"
  }
  assert {
    condition     = contains(output.enabled_exporters, "node") && contains(output.enabled_exporters, "syslogng")
    error_message = "enabled_exporters must list node + syslogng by default"
  }
}

# --- Fleet-wide CA trust (opt-in) — off by default, installs root CA when set --------

run "internal_ca_off_by_default" {
  command = plan

  assert {
    condition     = !strcontains(local_file.controller_ci.content, "internal-root-ca.crt")
    error_message = "with internal_ca_cert unset, controller cloud-init must NOT render the trust block"
  }
  assert {
    condition     = !strcontains(local_file.usg_ci.content, "internal-root-ca.crt")
    error_message = "with internal_ca_cert unset, usg cloud-init must NOT render the trust block"
  }
}

run "internal_ca_on_renders_trust" {
  command = plan

  variables {
    internal_ca_cert = "-----BEGIN CERTIFICATE-----\nMIITESTROOTCA\n-----END CERTIFICATE-----"
  }

  assert {
    condition     = strcontains(local_file.controller_ci.content, "/usr/local/share/ca-certificates/internal-root-ca.crt") && strcontains(local_file.controller_ci.content, "update-ca-certificates")
    error_message = "controller cloud-init must drop the internal root CA + run update-ca-certificates when internal_ca_cert is set"
  }
  assert {
    condition     = strcontains(local_file.usg_ci.content, "/usr/local/share/ca-certificates/internal-root-ca.crt") && strcontains(local_file.usg_ci.content, "update-ca-certificates")
    error_message = "usg cloud-init must drop the internal root CA + run update-ca-certificates when internal_ca_cert is set"
  }
  assert {
    condition     = strcontains(local_file.controller_ci.content, "MIITESTROOTCA")
    error_message = "controller trust block must carry the injected root CA PEM"
  }
}

# --- Internal NTP source (opt-in) — off by default, wires timesyncd when set --------

run "ntp_server_off_by_default" {
  command = plan
  assert {
    condition     = alltrue([for c in [local_file.usg_ci.content, local_file.controller_ci.content] : !strcontains(c, "99-centralized-ntp.conf")])
    error_message = "the internal NTP drop-in must be absent by default (ntp_server empty)"
  }
}

run "ntp_server_on_renders_dropin" {
  command = plan
  variables {
    ntp_server = "10.0.0.9"
  }
  assert {
    condition     = alltrue([for c in [local_file.usg_ci.content, local_file.controller_ci.content] : strcontains(c, "/etc/systemd/timesyncd.conf.d/99-centralized-ntp.conf")])
    error_message = "ntp_server set must render the timesyncd drop-in on every VM"
  }
  assert {
    condition     = alltrue([for c in [local_file.usg_ci.content, local_file.controller_ci.content] : strcontains(c, "NTP=10.0.0.9")])
    error_message = "the drop-in must point at the injected NTP IP"
  }
}

# --- Netdata agent (shared snippet) — default ON on every VM --------

run "netdata_render_by_default" {
  command = plan
  assert {
    condition     = strcontains(local_file.controller_ci.content, "install-netdata.sh") && strcontains(local_file.usg_ci.content, "install-netdata.sh")
    error_message = "both VMs must install Netdata by default"
  }
  assert {
    condition     = strcontains(local_file.controller_ci.content, "get.netdata.cloud/kickstart.sh") && strcontains(local_file.controller_ci.content, "lab-managed max-stats")
    error_message = "controller cloud-init must render the kickstart install + max-stats tuning block"
  }
  assert {
    condition     = strcontains(local_file.controller_ci.content, "role = controller") && strcontains(local_file.usg_ci.content, "role = usg")
    error_message = "each VM's Netdata [host labels] must carry its own role"
  }
  assert {
    condition     = can(yamldecode(local_file.controller_ci.content)) && can(yamldecode(local_file.usg_ci.content))
    error_message = "both cloud-inits must stay valid YAML after adding the Netdata installer"
  }
}

run "netdata_absent_when_disabled" {
  command = plan
  variables { enable_netdata = false }
  assert {
    condition     = !strcontains(local_file.controller_ci.content, "install-netdata.sh") && !strcontains(local_file.usg_ci.content, "install-netdata.sh")
    error_message = "disabled enable_netdata must omit the installer from both VMs"
  }
}
