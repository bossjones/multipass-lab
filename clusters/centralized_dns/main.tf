locals {
  # Explicit inline key wins; otherwise read the pubkey file if it exists; otherwise empty.
  ssh_pubkey = var.ssh_pubkey != "" ? var.ssh_pubkey : (
    fileexists(pathexpand(var.ssh_pubkey_path)) ? trimspace(file(pathexpand(var.ssh_pubkey_path))) : ""
  )

  render_dir  = "${path.module}/.rendered"
  server_name = "${var.name_prefix}-server"

  # One map of every exporter feature flag, merged into the cloud-init render so the
  # %{ if enable_x ~} blocks toggle each install (mirrors the other clusters).
  flags = {
    enable_node_exporter    = var.enable_node_exporter
    enable_unbound_exporter = var.enable_unbound_exporter
    enable_adguard_exporter = var.enable_adguard_exporter
    enable_process_exporter = var.enable_process_exporter
    enable_systemd_exporter = var.enable_systemd_exporter
  }

  # Sorted list of active flags — exported as enabled_flags and consumed by the CLIs +
  # tests/testinfra/conftest.py so the live suite asserts only what is on.
  enabled_flags = sort([for k, v in local.flags : k if v])

  # --- AdGuard Home seed + Unbound config -----------------------------------
  # AdGuard Home is pre-seeded with an admin user + the Unbound upstream so first boot is
  # non-interactive (no setup wizard). Unbound is a hardened localhost-only recursive
  # resolver with a control socket for unbound_exporter.
  adguard_conf = templatefile("${path.module}/cloud-init/adguard/AdGuardHome.yaml.tftpl", {
    adguard_user          = var.adguard_user
    adguard_password_hash = var.adguard_password_hash
    adguard_web_port      = var.adguard_web_port
    upstream_unbound      = var.upstream_unbound
    blocklists            = var.blocklists
    dns_rewrites          = var.dns_rewrites
  })

  unbound_conf = file("${path.module}/cloud-init/unbound/unbound.conf")

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
}

# --- DNS VM (AdGuard Home + Unbound + exporters) ----------------------------

resource "local_file" "server_ci" {
  filename = "${local.render_dir}/server.yaml"
  content = templatefile("${path.module}/cloud-init/server.yaml.tftpl", merge(local.flags, {
    ssh_pubkey           = local.ssh_pubkey
    adguard_conf         = local.adguard_conf
    adguard_user         = var.adguard_user
    adguard_password     = var.adguard_password
    adguard_web_port     = var.adguard_web_port
    adguard_exporter_ver = var.adguard_exporter_version
    unbound_conf         = local.unbound_conf

    dns_server           = var.dns_server
    dns_resolved_conf    = local.dns_resolved_conf
    internal_ca_cert     = var.internal_ca_cert
    log_shipping_target  = var.log_shipping_target
    openobserve_endpoint = var.openobserve_endpoint
    syslog_client_conf   = local.syslog_client_conf
    otel_agent_conf      = local.otel_agent_conf
  }))
}

resource "multipass_instance" "server" {
  name           = local.server_name
  image          = var.image
  cpus           = var.server.cpus
  memory         = var.server.memory
  disk           = var.server.disk
  cloudinit_file = local_file.server_ci.filename
}

# --- Hot-push artifacts (see specs/cross-cluster.md § self-telemetry) --------
# This cluster boots FIRST (before the logging/monitoring hubs), so its own log-shipping
# is wired AFTER the fact by `just up-connected`: it sets log_shipping_target/
# openobserve_endpoint, re-applies (a content-only change — never recreates the VM, so the
# DNS IP the whole fleet points at stays stable), which materializes these rendered drop-ins
# for scp onto the running VM. count=0 (empty files absent) keeps a plain `just up` clean.
resource "local_file" "ship_conf" {
  count    = local.ship_logs ? 1 : 0
  filename = "${local.render_dir}/10-ship.conf"
  content  = local.syslog_client_conf
}

resource "local_file" "otel_conf" {
  count    = local.push_otlp ? 1 : 0
  filename = "${local.render_dir}/otel-config.yaml"
  content  = local.otel_agent_conf
}

# The seeded AdGuard config, rendered standalone so `just dns-register <cluster>` can hot-push
# updated host rewrites (internal-CA TLS hostnames) onto the running VM without a recreate — the
# DNS IP the whole fleet points at must stay stable. Always present (mirrors the embedded copy in
# server.yaml's write_files). See specs/internal-ca.md.
resource "local_file" "adguard_conf" {
  filename = "${local.render_dir}/AdGuardHome.yaml"
  content  = local.adguard_conf
}
