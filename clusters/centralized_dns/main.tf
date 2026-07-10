locals {
  # Explicit inline key wins; otherwise read the pubkey file if it exists; otherwise empty.
  ssh_pubkey = var.ssh_pubkey != "" ? var.ssh_pubkey : (
    fileexists(pathexpand(var.ssh_pubkey_path)) ? trimspace(file(pathexpand(var.ssh_pubkey_path))) : ""
  )

  render_dir  = "${path.module}/.rendered"
  server_name = "${var.name_prefix}-server"

  # The keepalived peer-push provisioner SSHes to the HA nodes itself (multipass exec/transfer
  # don't route to VMs in this environment — see CLAUDE.md), same idiom as centralized_k0s.
  ssh_private_key = trimsuffix(pathexpand(var.ssh_pubkey_path), ".pub")
  ssh_opts        = "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8 -i ${local.ssh_private_key}"

  # --- HA (opt-in; see specs/ha-dns.md) ---------------------------------------
  # Off (default) = today's single `server` VM, unchanged. On = primary+secondary behind a
  # keepalived VIP. `multipass_instance.server` stays its OWN resource (gated count, not
  # for_each) so a plain `just up` never changes that resource's state address — converting it
  # to a for_each keyed "server" would show as destroy+create on every existing deployment even
  # with enable_ha left false, since OpenTofu tracks resources by address, not by name.
  ha              = var.enable_ha
  node_priorities = { primary = 200, secondary = 100 }
  node_state      = { primary = "MASTER", secondary = "BACKUP" }
  active_roles    = local.ha ? keys(local.node_priorities) : ["server"]

  # dns_endpoint: what the FLEET resolves against (dns_server on every other cluster).
  dns_endpoint = local.ha ? var.vip_address : multipass_instance.server[0].ipv4
  # dns_rewrite_target: where `just set-dns-all` pushes rewrites — the ORIGIN in HA mode, so
  # AdGuardHome-Sync replicates them to secondary (pushing at the VIP would race the next sync).
  dns_rewrite_target = local.ha ? multipass_instance.node["primary"].ipv4 : multipass_instance.server[0].ipv4

  # One map of every exporter feature flag, merged into the cloud-init render so the
  # %{ if enable_x ~} blocks toggle each install (mirrors the other clusters).
  flags = {
    enable_node_exporter    = var.enable_node_exporter
    enable_unbound_exporter = var.enable_unbound_exporter
    enable_adguard_exporter = var.enable_adguard_exporter
    enable_process_exporter = var.enable_process_exporter
    enable_systemd_exporter = var.enable_systemd_exporter
    enable_netdata          = var.enable_netdata
  }

  # Sorted list of active flags — exported as enabled_flags and consumed by the CLIs +
  # tests/testinfra/conftest.py so the live suite asserts only what is on.
  enabled_flags = sort([for k, v in local.flags : k if v])

  # --- AdGuard Home seed + Unbound config -----------------------------------
  # AdGuard Home is pre-seeded with an admin user + the Unbound upstream so first boot is
  # non-interactive (no setup wizard). Unbound is a hardened localhost-only recursive
  # resolver with a control socket for unbound_exporter. Identical on every node at first boot;
  # AdGuardHome-Sync keeps primary/secondary identical after (HA mode).
  adguard_conf = templatefile("${path.module}/cloud-init/adguard/AdGuardHome.yaml.tftpl", {
    adguard_user          = var.adguard_user
    adguard_password_hash = var.adguard_password_hash
    adguard_web_port      = var.adguard_web_port
    upstream_unbound      = var.upstream_unbound
    blocklists            = var.blocklists
  })

  unbound_conf = file("${path.module}/cloud-init/unbound/unbound.conf")

  # --- Netdata agent (shared snippet; opt-in default on, see specs/shared-netdata.md) ---
  # Rendered per-role (role-tagged host_labels) from the shared installer; empty when off.
  netdata_installer = {
    for role in local.active_roles :
    role => var.enable_netdata ? templatefile("${path.module}/../_shared/cloud-init/install-netdata.sh.tftpl", {
      host_labels = { cluster = var.name_prefix, role = role, environment = "lab" }
      enable_ebpf = var.enable_netdata_ebpf
    }) : ""
  }

  # --- Cross-cluster telemetry snippets (opt-in; see specs/cross-cluster.md) ---
  # Rendered from the SHARED clusters/_shared/cloud-init/ snippets only when the matching
  # target is set; empty string otherwise so the cloud-init %{ if ... != "" } guards drop
  # the whole block. host:port is split; the port defaults if the target omits it.
  ship_logs = var.log_shipping_target != ""
  push_otlp = var.openobserve_endpoint != ""

  syslog_client_conf = local.ship_logs ? templatefile("${path.module}/../_shared/cloud-init/syslog-client.conf.tftpl", {
    central_ip  = split(":", var.log_shipping_target)[0]
    syslog_port = try(split(":", var.log_shipping_target)[1], "514")
  }) : ""

  otel_agent_conf = local.push_otlp ? templatefile("${path.module}/../_shared/cloud-init/otel-agent-config.yaml.tftpl", {
    openobserve_ip       = split(":", var.openobserve_endpoint)[0]
    openobserve_port     = try(split(":", var.openobserve_endpoint)[1], "5080")
    openobserve_org      = var.openobserve_org
    openobserve_password = var.openobserve_password
    stream_name          = "${replace(var.name_prefix, "-", "_")}_server"
  }) : ""

  # Cross-cluster resolver: for THIS cluster dns_server is empty (the DNS VM points at its
  # own AdGuard at 127.0.0.1 via cloud-init), but the var + local exist for contract symmetry.
  use_dns = var.dns_server != ""
  dns_resolved_conf = local.use_dns ? templatefile("${path.module}/../_shared/cloud-init/use-dns.conf.tftpl", {
    dns_ip = split(":", var.dns_server)[0]
  }) : ""

  # --- Baseline time sync (unconditional; see specs/shared-ntp.md) -------------
  # Single-sourced UTC + systemd-timesyncd block, injected at column 0 of every VM template so
  # all fleet renders are byte-identical and cannot drift.
  ntp_timesync = templatefile("${path.module}/../_shared/cloud-init/ntp-timesync.yaml.tftpl", {})

  # Opt-in internal NTP source — mirrors dns_server. Non-empty -> every VM points
  # systemd-timesyncd at ntp_ip (by IP, so it never races DNS at boot). See specs/shared-ntp.md.
  use_ntp = var.ntp_server != ""
  ntp_conf = local.use_ntp ? templatefile("${path.module}/../_shared/cloud-init/use-ntp.conf.tftpl", {
    ntp_ip = split(":", var.ntp_server)[0]
  }) : ""

  # --- HA: keepalived health probe (identical on every node; no vars) ---------
  chk_adguard_script = templatefile("${path.module}/cloud-init/keepalived/chk_adguard.sh.tftpl", {})

  # --- HA: keepalived config rendered PEER-LESS for first boot ----------------
  # unicast_src_ip/interface can't be known at render time (Multipass DHCP-assigns the VM's IP
  # only after it boots) and peer_ip can't be known before BOTH nodes exist. Baking either the
  # keepalived peer IP OR AdGuardHome-Sync's secondary_ip into node_ci's first-boot render (a
  # for_each resource referencing another for_each resource) is a whole-resource cycle to
  # OpenTofu's graph analysis — confirmed via `tofu validate` — even for the AdGuardHome-Sync case
  # where only one direction (primary -> secondary) is actually referenced per instance. So BOTH
  # are deferred to standalone post-apply resources (`keepalived_peer_push`,
  # `adguardhome_sync_push` below), which are safe because they're separate resources not
  # consumed by multipass_instance.node.cloudinit_file. First boot here installs this peer-less
  # config + the health script but does NOT start keepalived; the post-apply push renders the real
  # peer-aware config once both node IPs exist, fills in the self-discovered iface/IP over SSH,
  # and starts the service for the first time. See specs/ha-dns.md "Open risk" + the plan's
  # peer-IP correction.
  keepalived_conf_bootstrap = {
    for role, priority in local.node_priorities :
    role => templatefile("${path.module}/cloud-init/keepalived/keepalived.conf.tftpl", {
      state            = local.node_state[role]
      priority         = priority
      vrrp_router_id   = var.vrrp_router_id
      vrrp_auth_pass   = var.vrrp_auth_pass
      vrrp_use_unicast = var.vrrp_use_unicast
      vip              = var.vip_address
      peer_ip          = "" # filled in by the post-apply push once both nodes exist
    })
  }
}

# --- Single-VM mode (enable_ha = false, the default) ------------------------
# Untouched resource addresses (multipass_instance.server / local_file.server_ci) — gated with
# `count` (not for_each) so a plain `just up` with enable_ha left at its default renders and
# addresses these EXACTLY as before the HA feature landed. See the `moved` blocks below for the
# one-time singleton->count[0] migration.

resource "local_file" "server_ci" {
  count    = local.ha ? 0 : 1
  filename = "${local.render_dir}/server.yaml"
  content = templatefile("${path.module}/cloud-init/server.yaml.tftpl", merge(local.flags, {
    ssh_pubkey           = local.ssh_pubkey
    adguard_conf         = local.adguard_conf
    adguard_user         = var.adguard_user
    adguard_password     = var.adguard_password
    adguard_web_port     = var.adguard_web_port
    adguard_exporter_ver = var.adguard_exporter_version
    unbound_conf         = local.unbound_conf
    netdata_installer    = local.netdata_installer["server"]

    ntp_timesync         = local.ntp_timesync
    ntp_server           = var.ntp_server
    ntp_conf             = local.ntp_conf
    enable_ntp_server    = var.enable_ntp_server
    dns_server           = var.dns_server
    dns_resolved_conf    = local.dns_resolved_conf
    internal_ca_cert     = var.internal_ca_cert
    log_shipping_target  = var.log_shipping_target
    openobserve_endpoint = var.openobserve_endpoint
    syslog_client_conf   = local.syslog_client_conf
    otel_agent_conf      = local.otel_agent_conf

    # HA is off for this resource by construction (count=0 when ha); pass inert defaults so
    # the shared, role-parameterized template doesn't need a second variable set.
    enable_ha                = false
    is_origin                = false
    role                     = "server"
    keepalived_conf          = ""
    chk_adguard_script       = ""
    adguardhome_sync_svc     = ""
    adguardhome_sync_version = var.adguardhome_sync_version
  }))
}

resource "multipass_instance" "server" {
  count          = local.ha ? 0 : 1
  name           = local.server_name
  image          = var.image
  cpus           = var.server.cpus
  memory         = var.server.memory
  disk           = var.server.disk
  cloudinit_file = local_file.server_ci[0].filename
}

# One-time migration: this cluster shipped `multipass_instance.server`/`local_file.server_ci` as
# plain singletons (no count) before the HA feature. Adding `count` changes their state address;
# these `moved` blocks let existing deployments migrate in place instead of destroying/recreating
# the DNS VM on the next apply. (Officially-supported "add count to a singleton" path — verify
# with a real `tofu plan` against existing state that the diff is empty when enable_ha=false.)
moved {
  from = multipass_instance.server
  to   = multipass_instance.server[0]
}

moved {
  from = local_file.server_ci
  to   = local_file.server_ci[0]
}

# --- HA mode (enable_ha = true): primary + secondary ------------------------
# A wholly SEPARATE resource from `multipass_instance.server` (mirrors centralized_k0s's
# dedicated `haproxy` resource, not a unified for_each) — single mode never touches this.

resource "local_file" "node_ci" {
  for_each = local.ha ? local.node_priorities : {}
  filename = "${local.render_dir}/${each.key}.yaml"
  content = templatefile("${path.module}/cloud-init/server.yaml.tftpl", merge(local.flags, {
    ssh_pubkey           = local.ssh_pubkey
    adguard_conf         = local.adguard_conf
    adguard_user         = var.adguard_user
    adguard_password     = var.adguard_password
    adguard_web_port     = var.adguard_web_port
    adguard_exporter_ver = var.adguard_exporter_version
    unbound_conf         = local.unbound_conf
    netdata_installer    = local.netdata_installer[each.key]

    ntp_timesync         = local.ntp_timesync
    ntp_server           = var.ntp_server
    ntp_conf             = local.ntp_conf
    enable_ntp_server    = var.enable_ntp_server
    dns_server           = var.dns_server
    dns_resolved_conf    = local.dns_resolved_conf
    internal_ca_cert     = var.internal_ca_cert
    log_shipping_target  = var.log_shipping_target
    openobserve_endpoint = var.openobserve_endpoint
    syslog_client_conf   = local.syslog_client_conf
    otel_agent_conf      = local.otel_agent_conf

    enable_ha          = true
    is_origin          = each.key == "primary"
    role               = each.key
    keepalived_conf    = local.keepalived_conf_bootstrap[each.key]
    chk_adguard_script = local.chk_adguard_script

    # AdGuardHome-Sync (primary only): the systemd unit is static and installs at first boot, but
    # the CONFIG needs secondary's IP — a for_each resource referencing another for_each resource
    # back and forth is treated as a whole-resource cycle by OpenTofu's graph (confirmed via `tofu
    # validate`), even though only one direction (primary -> secondary) is actually referenced per
    # instance. So the config is NOT rendered here; `adguardhome_sync_push` below writes the real
    # config (secondary_ip now resolvable, no cycle — it's a fresh resource, not node_ci) and
    # starts the service once both nodes exist. First boot installs the binary + unit only.
    adguardhome_sync_svc     = each.key == "primary" ? file("${path.module}/cloud-init/adguardhome-sync/adguardhome-sync.service") : ""
    adguardhome_sync_version = var.adguardhome_sync_version
  }))
}

resource "multipass_instance" "node" {
  for_each       = local.ha ? local.node_priorities : {}
  name           = "${var.name_prefix}-${each.key}"
  image          = var.image
  cpus           = var.server.cpus
  memory         = var.server.memory
  disk           = var.server.disk
  cloudinit_file = local_file.node_ci[each.key].filename
}

# --- HA: post-apply keepalived peer wiring ----------------------------------
# unicast_peer needs BOTH nodes' IPs in BOTH directions — a genuine primary<->secondary cycle if
# baked into first-boot cloud-init. Rendered here (both node IPs now known) and pushed over SSH
# once both VMs exist (mirrors centralized_k0s's terraform_data.k0s_bootstrap post-apply
# provisioning idiom): fills in each node's self-discovered interface/IP remotely (still unknown
# to Terraform), writes the real config, and starts keepalived for the first time.
resource "local_file" "keepalived_peer_conf" {
  for_each = local.ha ? local.node_priorities : {}
  filename = "${local.render_dir}/keepalived-${each.key}.conf"
  content = templatefile("${path.module}/cloud-init/keepalived/keepalived.conf.tftpl", {
    state            = local.node_state[each.key]
    priority         = each.value
    vrrp_router_id   = var.vrrp_router_id
    vrrp_auth_pass   = var.vrrp_auth_pass
    vrrp_use_unicast = var.vrrp_use_unicast
    vip              = var.vip_address
    peer_ip          = each.key == "primary" ? multipass_instance.node["secondary"].ipv4 : multipass_instance.node["primary"].ipv4
  })
}

resource "terraform_data" "keepalived_peer_push" {
  count = local.ha ? 1 : 0

  triggers_replace = [
    multipass_instance.node["primary"].ipv4,
    multipass_instance.node["secondary"].ipv4,
    local_file.keepalived_peer_conf["primary"].content,
    local_file.keepalived_peer_conf["secondary"].content,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      for role in primary secondary; do
        case "$role" in
          primary)   ip="${multipass_instance.node["primary"].ipv4}" ;;
          secondary) ip="${multipass_instance.node["secondary"].ipv4}" ;;
        esac
        conf="${local.render_dir}/keepalived-$role.conf"
        ssh -n ${local.ssh_opts} ubuntu@"$ip" 'cloud-init status --wait || true'
        scp ${local.ssh_opts} "$conf" ubuntu@"$ip":/tmp/keepalived.conf.new
        ssh -n ${local.ssh_opts} ubuntu@"$ip" '
          set -e
          iface=$(ip -4 route get 1.1.1.1 | awk "{for(i=1;i<=NF;i++) if (\$i==\"dev\") print \$(i+1)}")
          self_ip=$(ip -4 route get 1.1.1.1 | awk "{for(i=1;i<=NF;i++) if (\$i==\"src\") print \$(i+1)}")
          sudo sed -e "s/@@VRRP_IFACE@@/$iface/" -e "s/@@UNICAST_SRC_IP@@/$self_ip/" /tmp/keepalived.conf.new | sudo tee /etc/keepalived/keepalived.conf >/dev/null
          sudo systemctl enable --now keepalived
          sudo systemctl restart keepalived
        '
      done
    EOT
  }

  depends_on = [multipass_instance.node]
}

# --- HA: post-apply AdGuardHome-Sync config push (primary only) -------------
# The sync config needs secondary's real IP, which (like the keepalived peer) can't be baked into
# node_ci's first-boot render without the same whole-resource cycle. This local_file is a
# standalone resource (not consumed by multipass_instance.node), so referencing
# multipass_instance.node["secondary"] here is safe — it's evaluated only after both nodes exist.
resource "local_file" "adguardhome_sync_conf" {
  count    = local.ha ? 1 : 0
  filename = "${local.render_dir}/adguardhome-sync.yaml"
  content = templatefile("${path.module}/cloud-init/adguardhome-sync/adguardhome-sync.yaml.tftpl", {
    adguard_web_port = var.adguard_web_port
    adguard_user     = var.adguard_user
    adguard_password = var.adguard_password
    secondary_ip     = multipass_instance.node["secondary"].ipv4
    sync_interval    = var.sync_interval
  })
}

resource "terraform_data" "adguardhome_sync_push" {
  count = local.ha ? 1 : 0

  triggers_replace = [
    multipass_instance.node["primary"].ipv4,
    multipass_instance.node["secondary"].ipv4,
    local_file.adguardhome_sync_conf[0].content,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      primary_ip="${multipass_instance.node["primary"].ipv4}"
      ssh -n ${local.ssh_opts} ubuntu@"$primary_ip" 'cloud-init status --wait || true'
      scp ${local.ssh_opts} ${local_file.adguardhome_sync_conf[0].filename} ubuntu@"$primary_ip":/tmp/adguardhome-sync.yaml.new
      ssh -n ${local.ssh_opts} ubuntu@"$primary_ip" '
        set -e
        sudo install -o root -g root -m0600 /tmp/adguardhome-sync.yaml.new /etc/adguardhome-sync/adguardhome-sync.yaml
        sudo systemctl enable --now adguardhome-sync
        sudo systemctl restart adguardhome-sync
      '
    EOT
  }

  depends_on = [multipass_instance.node]
}

# --- Hot-push artifacts (see specs/cross-cluster.md § self-telemetry) --------
# This cluster boots FIRST (before the logging/monitoring hubs), so its own log-shipping is
# wired AFTER the fact by `just up-connected`: it sets log_shipping_target/openobserve_endpoint,
# re-applies (a content-only change — never recreates the VM, so dns_endpoint stays stable),
# which materializes these rendered drop-ins for scp onto the running VM(s). Single-mode
# resources are UNCHANGED in shape (count, same as before HA) so no address churn; HA mode gets
# its own parallel for_each resources, one per node.

resource "local_file" "ship_conf" {
  count    = (!local.ha && local.ship_logs) ? 1 : 0
  filename = "${local.render_dir}/server-ship.conf"
  content  = local.syslog_client_conf
}

resource "local_file" "otel_conf" {
  count    = (!local.ha && local.push_otlp) ? 1 : 0
  filename = "${local.render_dir}/server-otel.yaml"
  content  = local.otel_agent_conf
}

resource "local_file" "ntp_dropin" {
  count    = (!local.ha && local.use_ntp) ? 1 : 0
  filename = "${local.render_dir}/server-ntp.conf"
  content  = local.ntp_conf
}

resource "local_file" "node_ship_conf" {
  for_each = (local.ha && local.ship_logs) ? local.node_priorities : {}
  filename = "${local.render_dir}/${each.key}-ship.conf"
  content  = local.syslog_client_conf
}

resource "local_file" "node_otel_conf" {
  for_each = (local.ha && local.push_otlp) ? local.node_priorities : {}
  filename = "${local.render_dir}/${each.key}-otel.yaml"
  content  = local.otel_agent_conf
}

resource "local_file" "node_ntp_dropin" {
  for_each = (local.ha && local.use_ntp) ? local.node_priorities : {}
  filename = "${local.render_dir}/${each.key}-ntp.conf"
  content  = local.ntp_conf
}

# The seeded AdGuard config, rendered standalone (mirrors the embedded copy in server.yaml's
# write_files). Host rewrites start empty here; service hostnames are registered at runtime over
# the AdGuard REST API by `just set-dns` / `set-dns-all`. See specs/pki-and-dns.md. Identical
# for both modes — every node boots from this same seed.
resource "local_file" "adguard_conf" {
  filename = "${local.render_dir}/AdGuardHome.yaml"
  content  = local.adguard_conf
}
