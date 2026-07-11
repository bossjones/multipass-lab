# Layer 0/1 hermetic test — runs with `tofu test -test-directory=tests/tofu`.
# mock_provider means no Multipass is touched; command = plan asserts on rendered values.

mock_provider "multipass" {}

variables {
  # Provide an inline key so the test never depends on a real ~/.ssh file.
  ssh_pubkey = "ssh-ed25519 AAAATESTKEY centralized-dns-tests"
  # Pin the opt-in NTP source + hub OFF so an auto-loaded .cross-cluster.auto.tfvars.json (which
  # up-connected writes with ntp_server/enable_ntp_server when INTERNAL_NTP is set) can't flip the
  # off-by-default runs. See specs/shared-ntp.md + the CLAUDE.md auto-tfvars gotcha.
  ntp_server        = ""
  enable_ntp_server = false
  # Pin HA off at file scope too — a leftover HA-enabling .auto.tfvars would otherwise flip the
  # off-by-default regression-guard runs below. See the CLAUDE.md auto-tfvars gotcha.
  enable_ha   = false
  vip_address = ""
}

run "sizing_image_and_name" {
  command = plan

  assert {
    condition     = multipass_instance.server[0].cpus == 2
    error_message = "server cpus should be 2"
  }
  assert {
    condition     = multipass_instance.server[0].memory == "2G"
    error_message = "server memory should be 2G"
  }
  assert {
    condition     = multipass_instance.server[0].image == "24.04"
    error_message = "image should be 24.04"
  }
  assert {
    condition     = multipass_instance.server[0].name == "centralized-dns-server"
    error_message = "server name should carry the name_prefix"
  }
  # Single-mode regression guard (see specs/ha-dns.md): enable_ha=false must render exactly one
  # server VM and zero HA nodes/artifacts — the HA feature must be purely additive.
  assert {
    condition     = length(multipass_instance.server) == 1
    error_message = "single mode must create exactly one server VM"
  }
  assert {
    condition     = length(multipass_instance.node) == 0
    error_message = "single mode must create zero HA nodes (primary/secondary)"
  }
  assert {
    condition     = !strcontains(local_file.server_ci[0].content, "keepalived") && !strcontains(local_file.server_ci[0].content, "adguardhome-sync")
    error_message = "single mode cloud-init must contain zero keepalived/adguardhome-sync tokens"
  }
  assert {
    condition     = output.dns_endpoint == multipass_instance.server[0].ipv4
    error_message = "dns_endpoint must equal the single server VM's IP when enable_ha=false"
  }
  assert {
    condition     = output.dns_rewrite_target == multipass_instance.server[0].ipv4
    error_message = "dns_rewrite_target must equal the single server VM's IP when enable_ha=false"
  }
  assert {
    condition     = !contains(keys(output.hosts), "primary") && !contains(keys(output.hosts), "secondary")
    error_message = "hosts must not carry primary/secondary keys when enable_ha=false"
  }
  assert {
    condition     = output.enabled_features.ha == false
    error_message = "enabled_features.ha must be false when enable_ha=false"
  }
}

run "dns_stack_renders" {
  command = plan

  # AdGuard Home installed host-level via the official installer (NOT Docker).
  assert {
    condition     = strcontains(local_file.server_ci[0].content, "AdguardTeam/AdGuardHome/master/scripts/install.sh")
    error_message = "cloud-init must run the official AdGuard Home installer"
  }
  assert {
    condition     = !strcontains(local_file.server_ci[0].content, "docker compose")
    error_message = "the DNS stack must be host-level systemd, not Docker"
  }
  # AdGuard Home is pre-seeded (skips the wizard): admin user + Unbound upstream.
  assert {
    condition     = strcontains(local_file.server_ci[0].content, "/opt/AdGuardHome/AdGuardHome.yaml")
    error_message = "cloud-init must seed AdGuardHome.yaml"
  }
  assert {
    condition     = strcontains(local_file.server_ci[0].content, "name: admin")
    error_message = "seeded AdGuardHome.yaml must carry the admin user"
  }
  assert {
    condition     = strcontains(local_file.server_ci[0].content, "- 127.0.0.1:5335")
    error_message = "AdGuard Home must forward to the local Unbound upstream (127.0.0.1:5335)"
  }
  # Unbound: hardened, localhost-only, with a control socket for unbound_exporter.
  assert {
    condition     = strcontains(local_file.server_ci[0].content, "/etc/unbound/unbound.conf.d/centralized-dns.conf")
    error_message = "cloud-init must drop the Unbound config"
  }
  assert {
    condition     = strcontains(local_file.server_ci[0].content, "control-interface: /run/unbound.ctl")
    error_message = "Unbound must expose a control socket for unbound_exporter"
  }
  # Port 53 freed for AdGuard by disabling the resolved stub.
  assert {
    condition     = strcontains(local_file.server_ci[0].content, "DNSStubListener=no")
    error_message = "cloud-init must free :53 by disabling the systemd-resolved stub"
  }
  # SSH key injected.
  assert {
    condition     = strcontains(local_file.server_ci[0].content, "ssh-ed25519 AAAATESTKEY")
    error_message = "cloud-init must inject the SSH public key"
  }
  # Rendered cloud-init must stay valid YAML.
  assert {
    condition     = can(yamldecode(local_file.server_ci[0].content))
    error_message = "rendered cloud-init must be valid YAML"
  }
}

run "ntp_timezone_render" {
  command = plan

  assert {
    condition     = strcontains(local_file.server_ci[0].content, "timezone: Etc/UTC")
    error_message = "cloud-init must pin timezone: Etc/UTC"
  }
  assert {
    condition     = strcontains(local_file.server_ci[0].content, "ntp_client: systemd-timesyncd")
    error_message = "cloud-init must set the NTP client to systemd-timesyncd"
  }
  assert {
    condition     = strcontains(local_file.server_ci[0].content, "timedatectl set-timezone Etc/UTC")
    error_message = "cloud-init runcmd must enforce timezone Etc/UTC"
  }
}

run "ntp_server_off_by_default" {
  command = plan

  assert {
    condition     = !strcontains(local_file.server_ci[0].content, "99-centralized-ntp.conf")
    error_message = "the internal NTP drop-in must be absent by default (ntp_server empty)"
  }
}

run "ntp_server_on_renders_dropin" {
  command = plan

  variables {
    ntp_server = "10.0.0.9"
  }

  assert {
    condition     = strcontains(local_file.server_ci[0].content, "/etc/systemd/timesyncd.conf.d/99-centralized-ntp.conf")
    error_message = "ntp_server set must render the timesyncd drop-in"
  }
  assert {
    condition     = strcontains(local_file.server_ci[0].content, "NTP=10.0.0.9")
    error_message = "the drop-in must point at the injected NTP IP"
  }
}

run "ntp_hub_off_by_default" {
  command = plan

  assert {
    condition     = !strcontains(local_file.server_ci[0].content, "/etc/chrony/conf.d/lab-ntp.conf")
    error_message = "the chrony NTP server must be absent by default (enable_ntp_server=false)"
  }
}

run "ntp_hub_on_installs_chrony" {
  command = plan

  variables {
    enable_ntp_server = true
  }

  assert {
    condition     = strcontains(local_file.server_ci[0].content, "/etc/chrony/conf.d/lab-ntp.conf")
    error_message = "enable_ntp_server must render the chrony server drop-in"
  }
  assert {
    condition     = strcontains(local_file.server_ci[0].content, "apt-get install -y chrony")
    error_message = "enable_ntp_server must install chrony to serve the fleet"
  }
}

run "exporters_render_by_default" {
  command = plan

  assert {
    condition     = strcontains(local_file.server_ci[0].content, "node_exporter-1.8.2")
    error_message = "node_exporter must install by default"
  }
  assert {
    condition     = strcontains(local_file.server_ci[0].content, "adguard-exporter@v1.2.1")
    error_message = "adguard-exporter must build at the pinned version by default"
  }
  assert {
    condition     = strcontains(local_file.server_ci[0].content, "unbound_exporter")
    error_message = "unbound_exporter must install by default"
  }
  assert {
    condition     = strcontains(local_file.server_ci[0].content, "BIND_ADDR=:9618")
    error_message = "adguard-exporter must bind :9618"
  }
  assert {
    condition     = strcontains(local_file.server_ci[0].content, "-unbound.host unix:///run/unbound.ctl")
    error_message = "unbound_exporter must read Unbound's control socket"
  }
  assert {
    condition     = strcontains(local_file.server_ci[0].content, "process-exporter-0.8.7") && strcontains(local_file.server_ci[0].content, "systemd_exporter-0.7.0")
    error_message = "process + systemd exporters must install by default"
  }
}

run "exporters_off_omit_install" {
  command = plan

  variables {
    enable_adguard_exporter = false
    enable_unbound_exporter = false
    enable_node_exporter    = false
    enable_process_exporter = false
    enable_systemd_exporter = false
  }

  assert {
    condition     = !strcontains(local_file.server_ci[0].content, "github.com/henrywhitaker3/adguard-exporter")
    error_message = "disabled adguard-exporter must not build/install"
  }
  assert {
    condition     = !strcontains(local_file.server_ci[0].content, "github.com/letsencrypt/unbound_exporter")
    error_message = "disabled unbound_exporter must not build/install"
  }
  assert {
    condition     = !strcontains(local_file.server_ci[0].content, "node_exporter-1.8.2")
    error_message = "disabled node_exporter must not install"
  }
}

run "web_urls_core_and_flag_aware" {
  command = plan

  assert {
    condition     = length(output.web_urls.core) == 1
    error_message = "web_urls.core must list just the AdGuard Home UI"
  }
  assert {
    condition     = length(output.web_urls.all) > length(output.web_urls.core)
    error_message = "web_urls.all must add the /metrics endpoints on top of core"
  }
  assert {
    condition     = contains(output.enabled_flags, "enable_adguard_exporter") && contains(output.enabled_flags, "enable_unbound_exporter")
    error_message = "enabled_flags must reflect the default exporter set"
  }
}

# --- Netdata agent (shared snippet; opt-in default on, see specs/shared-netdata.md) -----------

run "netdata_render_by_default" {
  command = plan
  assert {
    condition     = strcontains(local_file.server_ci[0].content, "install-netdata.sh")
    error_message = "the server VM must install Netdata by default"
  }
  assert {
    condition     = strcontains(local_file.server_ci[0].content, "get.netdata.cloud/kickstart.sh") && strcontains(local_file.server_ci[0].content, "lab-managed max-stats")
    error_message = "server cloud-init must render the kickstart install + the max-stats tuning block"
  }
  assert {
    condition     = strcontains(local_file.server_ci[0].content, "role = server")
    error_message = "Netdata [host labels] must carry the server role"
  }
  assert {
    condition     = can(yamldecode(local_file.server_ci[0].content))
    error_message = "server cloud-init must stay valid YAML after adding the Netdata installer"
  }
}

run "netdata_absent_when_disabled" {
  command = plan
  variables { enable_netdata = false }
  assert {
    condition     = !strcontains(local_file.server_ci[0].content, "install-netdata.sh")
    error_message = "disabled enable_netdata must omit the installer"
  }
}

# --- reverse_proxy_routes contract (fleet-edge Traefik; see specs/dynamic-traefik.md) ----------

run "reverse_proxy_routes_contract" {
  command = plan

  assert {
    condition     = length(output.reverse_proxy_routes) == 1
    error_message = "dns must publish exactly one fleet-edge route (AdGuard UI)"
  }
  assert {
    condition     = output.reverse_proxy_routes[0].host == "adguard" && output.reverse_proxy_routes[0].port == var.adguard_web_port
    error_message = "the adguard route must use host=adguard and the configured adguard_web_port"
  }
}

# --- HA mode (enable_ha = true; see specs/ha-dns.md) -------------------------------------------
# Mirrors clusters/centralized_k0s/tests/tofu/sizing_and_render.tftest.hcl's "ha_3cp_3w_topology":
# inline variables{} override within the run block flips HA on for just this run.

run "ha_2node_topology" {
  command = plan

  variables {
    enable_ha   = true
    vip_address = "10.10.10.99"
  }

  assert {
    condition     = length(multipass_instance.node) == 2
    error_message = "HA mode must create exactly two nodes (primary, secondary)"
  }
  assert {
    condition     = length(multipass_instance.server) == 0
    error_message = "HA mode must create zero single-mode server VMs"
  }
  assert {
    condition     = multipass_instance.node["primary"].name == "centralized-dns-primary"
    error_message = "primary VM must be named <prefix>-primary"
  }
  assert {
    condition     = multipass_instance.node["secondary"].name == "centralized-dns-secondary"
    error_message = "secondary VM must be named <prefix>-secondary"
  }
  assert {
    condition     = strcontains(local_file.node_ci["primary"].content, "keepalived") && strcontains(local_file.node_ci["secondary"].content, "keepalived")
    error_message = "both HA nodes must render the keepalived install/config"
  }
  assert {
    condition     = strcontains(local_file.keepalived_peer_conf["primary"].content, "state MASTER") && strcontains(local_file.keepalived_peer_conf["primary"].content, "priority 200")
    error_message = "primary's post-apply keepalived config must be MASTER/200"
  }
  assert {
    condition     = strcontains(local_file.keepalived_peer_conf["secondary"].content, "state BACKUP") && strcontains(local_file.keepalived_peer_conf["secondary"].content, "priority 100")
    error_message = "secondary's post-apply keepalived config must be BACKUP/100"
  }
  assert {
    condition     = strcontains(local_file.keepalived_peer_conf["primary"].content, "unicast_peer") && strcontains(local_file.keepalived_peer_conf["secondary"].content, "unicast_peer")
    error_message = "the post-apply peer-aware keepalived config must carry unicast_peer on both nodes"
  }
  assert {
    condition     = !strcontains(local_file.node_ci["primary"].content, "unicast_peer") && !strcontains(local_file.node_ci["secondary"].content, "unicast_peer")
    error_message = "the FIRST-BOOT keepalived config must be peer-less (peer wiring is a post-apply push, not baked into cloud-init)"
  }
  assert {
    condition     = strcontains(local_file.node_ci["primary"].content, "adguardhome-sync")
    error_message = "primary must install the AdGuardHome-Sync unit"
  }
  assert {
    condition     = !strcontains(local_file.node_ci["secondary"].content, "adguardhome-sync")
    error_message = "secondary must NOT install AdGuardHome-Sync (unidirectional replication from primary)"
  }
  assert {
    condition     = strcontains(local_file.adguardhome_sync_conf[0].content, "replicas")
    error_message = "the post-apply adguardhome-sync config must render the replicas block"
  }
  assert {
    condition     = output.dns_endpoint == var.vip_address
    error_message = "dns_endpoint must equal vip_address in HA mode"
  }
  assert {
    condition     = output.dns_rewrite_target == multipass_instance.node["primary"].ipv4
    error_message = "dns_rewrite_target must equal primary's IP in HA mode (the sync origin)"
  }
  assert {
    condition     = contains(keys(output.hosts), "primary") && contains(keys(output.hosts), "secondary")
    error_message = "hosts must carry primary/secondary keys in HA mode"
  }
  assert {
    condition     = output.enabled_features.ha == true
    error_message = "enabled_features.ha must be true in HA mode"
  }
  assert {
    condition     = can(yamldecode(local_file.node_ci["primary"].content)) && can(yamldecode(local_file.node_ci["secondary"].content))
    error_message = "both HA nodes' rendered cloud-init must stay valid YAML"
  }
}

run "ha_requires_vip_address" {
  command = plan

  variables {
    enable_ha   = true
    vip_address = ""
  }

  expect_failures = [
    var.enable_ha,
  ]
}
