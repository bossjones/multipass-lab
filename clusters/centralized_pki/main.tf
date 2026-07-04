locals {
  # Explicit inline key wins; otherwise read the pubkey file if it exists; otherwise empty.
  ssh_pubkey = var.ssh_pubkey != "" ? var.ssh_pubkey : (
    fileexists(pathexpand(var.ssh_pubkey_path)) ? trimspace(file(pathexpand(var.ssh_pubkey_path))) : ""
  )

  render_dir = "${path.module}/.rendered"

  # Interactive docker tooling installer (wharf/oxker/dive), shared byte-identically across
  # every cluster with a docker VM. Static script → file() (no templating); embedded into both
  # VM cloud-inits via write_files and run under enable_docker_tools (both VMs run docker).
  docker_tools_installer = file("${path.module}/../_shared/cloud-init/install-docker-tools.sh")

  ca_name       = "${var.name_prefix}-ca"
  services_name = "${var.name_prefix}-services"

  # One map of every feature flag, merged into every templatefile() call so each cloud-init
  # template renders its own %{ if enable_x ~}…%{ endif ~} blocks (mirrors the other clusters).
  flags = {
    enable_node_exporter       = var.enable_node_exporter
    enable_process_exporter    = var.enable_process_exporter
    enable_systemd_exporter    = var.enable_systemd_exporter
    enable_letsencrypt_staging = var.enable_letsencrypt_staging
    enable_netdata             = var.enable_netdata
  }

  # Netdata agent installer (shared snippet), rendered per-VM so [host labels] carry this VM's
  # cluster+role (they ride on netdata_info{...}). Empty when disabled -> the %{ if enable_netdata }
  # write_files/runcmd guards drop the block. See specs/shared-netdata.md.
  netdata_installer_ca = var.enable_netdata ? templatefile("${path.module}/../_shared/cloud-init/install-netdata.sh.tftpl", {
    host_labels = { cluster = var.name_prefix, role = "ca", environment = "lab" }
    enable_ebpf = var.enable_netdata_ebpf
  }) : ""

  netdata_installer_services = var.enable_netdata ? templatefile("${path.module}/../_shared/cloud-init/install-netdata.sh.tftpl", {
    host_labels = { cluster = var.name_prefix, role = "services", environment = "lab" }
    enable_ebpf = var.enable_netdata_ebpf
  }) : ""

  # Sorted list of active flags — exported as enabled_flags and consumed by the CLIs
  # (tls_cli picks the expected root from enable_letsencrypt_staging) and by
  # tests/testinfra/conftest.py so the live suite asserts only what is on.
  enabled_flags = sort([for k, v in local.flags : k if v])

  # step-ca API base + provisioner names. DOCKER_STEPCA_INIT_ACME=true adds an ACME provisioner
  # named "acme" (used by the LE-staging path's tooling parity + informational output); the docker
  # init also creates the initial JWK provisioner named by DOCKER_STEPCA_INIT_PROVISIONER_NAME
  # ("admin" here), which the services VM uses to issue Traefik's cert directly (password auth, no
  # ACME challenge — the DNS-less lab can't satisfy tls-alpn-01/http-01 reachback).
  ca_url             = "https://ca.${var.domain}:9000"
  acme_provisioner   = "acme"
  jwk_provisioner    = "admin"
  acme_directory_url = "${local.ca_url}/acme/${local.acme_provisioner}/directory"

  # Pin the persisted root/intermediate over step-ca's self-generated pair when all three are
  # provided (scripts/init_ca.py). Empty => step-ca self-inits an ephemeral root (today's behavior).
  # See specs/internal-ca.md.
  pin_ca = var.root_ca_cert != "" && var.intermediate_ca_cert != "" && var.intermediate_ca_key != ""

  # --- CA VM sub-config (step-ca compose) ---------------------------------
  # The CA's own IP can't be self-referenced in tofu, so DNS names carry a $${SELF_IP}
  # placeholder substituted at boot by a runcmd (the __SELF_IP__ pattern from docker-client).
  ca_compose = templatefile("${path.module}/cloud-init/step-ca/compose.yaml.tftpl", {
    ca_name            = local.ca_name
    domain             = var.domain
    stepca_ca_password = var.stepca_ca_password
  })

  # --- services VM sub-configs -------------------------------------------
  compose_conf = templatefile("${path.module}/cloud-init/docker/compose.yaml.tftpl", merge(local.flags, {
    domain                  = var.domain
    godaddy_api_key         = var.godaddy_api_key
    godaddy_api_secret      = var.godaddy_api_secret
    vaultwarden_admin_token = var.vaultwarden_admin_token
  }))

  traefik_static = templatefile("${path.module}/cloud-init/traefik/traefik.yaml.tftpl", merge(local.flags, {
    domain     = var.domain
    acme_email = var.acme_email
  }))

  traefik_dynamic = templatefile("${path.module}/cloud-init/traefik/dynamic.yaml.tftpl", merge(local.flags, {
    domain = var.domain
  }))

  # Static (no templating) placeholder for the fleet-wide routing table — see specs/dynamic-traefik.md.
  traefik_fleet_seed = file("${path.module}/cloud-init/traefik/fleet.yaml.seed")

  authelia_conf = templatefile("${path.module}/cloud-init/authelia/configuration.yaml.tftpl", {
    domain                  = var.domain
    authelia_session_secret = var.authelia_session_secret
    authelia_storage_key    = var.authelia_storage_key
    authelia_jwt_secret     = var.authelia_jwt_secret
  })

  authelia_users = templatefile("${path.module}/cloud-init/authelia/users_database.yaml.tftpl", {
    domain                 = var.domain
    authelia_user          = var.authelia_user
    authelia_password_hash = var.authelia_password_hash
  })

  # --- Cross-cluster telemetry snippets (opt-in; see specs/cross-cluster.md) ---
  # Rendered from the SHARED clusters/_shared/cloud-init/ snippets only when the matching target
  # is set; empty string otherwise so the cloud-init %{ if ... != "" } guards drop the whole block.
  # host:port is split into components; the port defaults if the target omits it.
  ship_logs = var.log_shipping_target != ""
  push_otlp = var.openobserve_endpoint != ""

  syslog_client_conf = local.ship_logs ? templatefile("${path.module}/../_shared/cloud-init/syslog-client.conf.tftpl", {
    central_ip  = split(":", var.log_shipping_target)[0]
    syslog_port = try(split(":", var.log_shipping_target)[1], "514")
  }) : ""

  # Cross-cluster DNS — point systemd-resolved at the centralized_dns AdGuard Home hub. Only the
  # host portion is used (systemd-resolved DNS= takes an IP); a host:port target has the port dropped.
  use_dns = var.dns_server != ""
  dns_resolved_conf = local.use_dns ? templatefile("${path.module}/../_shared/cloud-init/use-dns.conf.tftpl", {
    dns_ip = split(":", var.dns_server)[0]
  }) : ""

  # --- Baseline time sync (unconditional; see specs/shared-ntp.md) -------------
  # Single-sourced UTC + systemd-timesyncd block, injected at column 0 of every VM template.
  ntp_timesync = templatefile("${path.module}/../_shared/cloud-init/ntp-timesync.yaml.tftpl", {})

  # Opt-in internal NTP source — mirrors dns_server. Non-empty -> timesyncd points at ntp_ip (by IP).
  use_ntp = var.ntp_server != ""
  ntp_conf = local.use_ntp ? templatefile("${path.module}/../_shared/cloud-init/use-ntp.conf.tftpl", {
    ntp_ip = split(":", var.ntp_server)[0]
  }) : ""

  # One OTLP agent config per VM — OpenObserve derives the destination stream from stream-name,
  # so the ca and services VMs land in distinct streams.
  otel_agent_conf_ca = local.push_otlp ? templatefile("${path.module}/../_shared/cloud-init/otel-agent-config.yaml.tftpl", {
    openobserve_ip       = split(":", var.openobserve_endpoint)[0]
    openobserve_port     = try(split(":", var.openobserve_endpoint)[1], "5080")
    openobserve_org      = var.openobserve_org
    openobserve_password = var.openobserve_password
    stream_name          = "${replace(var.name_prefix, "-", "_")}_ca"
  }) : ""

  otel_agent_conf_services = local.push_otlp ? templatefile("${path.module}/../_shared/cloud-init/otel-agent-config.yaml.tftpl", {
    openobserve_ip       = split(":", var.openobserve_endpoint)[0]
    openobserve_port     = try(split(":", var.openobserve_endpoint)[1], "5080")
    openobserve_org      = var.openobserve_org
    openobserve_password = var.openobserve_password
    stream_name          = "${replace(var.name_prefix, "-", "_")}_services"
  }) : ""
}

# --- CA VM (step-ca) — created FIRST ----------------------------------------

resource "local_file" "ca_ci" {
  filename = "${local.render_dir}/ca.yaml"
  content = templatefile("${path.module}/cloud-init/ca.yaml.tftpl", merge(local.flags, {
    ssh_pubkey           = local.ssh_pubkey
    domain               = var.domain
    ca_compose           = local.ca_compose
    log_shipping_target  = var.log_shipping_target
    openobserve_endpoint = var.openobserve_endpoint
    syslog_client_conf   = local.syslog_client_conf
    otel_agent_conf      = local.otel_agent_conf_ca
    ntp_timesync         = local.ntp_timesync
    ntp_server           = var.ntp_server
    ntp_conf             = local.ntp_conf
    dns_server           = var.dns_server
    dns_resolved_conf    = local.dns_resolved_conf
    # Fleet-wide trust of the internal root CA (specs/internal-ca.md).
    internal_ca_cert = var.internal_ca_cert
    # Persisted-root pinning (Phase 0). pin_ca gates a runcmd that swaps step-ca's self-generated
    # root/intermediate for this pinned pair so the CA identity survives `just recreate`.
    pin_ca               = local.pin_ca
    root_ca_cert         = var.root_ca_cert
    intermediate_ca_cert = var.intermediate_ca_cert
    intermediate_ca_key  = var.intermediate_ca_key
    # Docker operator TUIs (wharf/oxker/dive) — the CA VM runs docker (step-ca).
    enable_docker_tools    = var.enable_docker_tools
    docker_tools_installer = local.docker_tools_installer
    # Netdata agent (:19999) — installed by the shared snippet. enable_netdata rides in local.flags.
    netdata_installer = local.netdata_installer_ca
  }))
}

resource "multipass_instance" "ca" {
  name           = local.ca_name
  image          = var.image
  cpus           = var.ca.cpus
  memory         = var.ca.memory
  disk           = var.ca.disk
  cloudinit_file = local_file.ca_ci.filename
}

# --- Services VM (Traefik + Authelia + Vaultwarden) -------------------------
# References multipass_instance.ca.ipv4 (via compose_conf) so the ca VM is created and its
# DHCP IP known before this renders/launches — the same edge centralized_logging creates
# between central and its clients.

resource "local_file" "services_ci" {
  filename = "${local.render_dir}/services.yaml"
  content = templatefile("${path.module}/cloud-init/services.yaml.tftpl", merge(local.flags, {
    ssh_pubkey         = local.ssh_pubkey
    domain             = var.domain
    ca_ip              = multipass_instance.ca.ipv4
    ca_url             = local.ca_url
    jwk_provisioner    = local.jwk_provisioner
    stepca_ca_password = var.stepca_ca_password
    compose_conf       = local.compose_conf
    traefik_static     = local.traefik_static
    traefik_dynamic    = local.traefik_dynamic
    traefik_fleet_seed = local.traefik_fleet_seed
    authelia_conf      = local.authelia_conf
    authelia_users     = local.authelia_users

    log_shipping_target  = var.log_shipping_target
    openobserve_endpoint = var.openobserve_endpoint
    syslog_client_conf   = local.syslog_client_conf
    otel_agent_conf      = local.otel_agent_conf_services
    ntp_timesync         = local.ntp_timesync
    ntp_server           = var.ntp_server
    ntp_conf             = local.ntp_conf
    dns_server           = var.dns_server
    dns_resolved_conf    = local.dns_resolved_conf
    # Fleet-wide trust of the internal root CA (specs/internal-ca.md).
    internal_ca_cert = var.internal_ca_cert
    # Docker operator TUIs (wharf/oxker/dive) — the services VM runs docker (Traefik/Authelia/etc).
    enable_docker_tools    = var.enable_docker_tools
    docker_tools_installer = local.docker_tools_installer
    # Netdata agent (:19999) — installed by the shared snippet. enable_netdata rides in local.flags.
    netdata_installer = local.netdata_installer_services
  }))
}

resource "multipass_instance" "services" {
  name           = local.services_name
  image          = var.image
  cpus           = var.services.cpus
  memory         = var.services.memory
  disk           = var.services.disk
  cloudinit_file = local_file.services_ci.filename
}

# --- Hot-push artifacts (see specs/cross-cluster.md; `just refresh-cross-cluster`) ---
# Discrete per-VM renders of the cross-cluster drop-ins, so a hub IP change can be scp'd onto an
# already-running VM (content-only tofu apply, no recreate) instead of requiring a full reprovision.
resource "local_file" "ca_resolved_conf" {
  count    = local.use_dns ? 1 : 0
  filename = "${local.render_dir}/ca-resolved.conf"
  content  = local.dns_resolved_conf
}

resource "local_file" "services_resolved_conf" {
  count    = local.use_dns ? 1 : 0
  filename = "${local.render_dir}/services-resolved.conf"
  content  = local.dns_resolved_conf
}

resource "local_file" "ca_ntp_conf" {
  count    = local.use_ntp ? 1 : 0
  filename = "${local.render_dir}/ca-ntp.conf"
  content  = local.ntp_conf
}

resource "local_file" "services_ntp_conf" {
  count    = local.use_ntp ? 1 : 0
  filename = "${local.render_dir}/services-ntp.conf"
  content  = local.ntp_conf
}

resource "local_file" "ca_ship_conf" {
  count    = local.ship_logs ? 1 : 0
  filename = "${local.render_dir}/ca-ship.conf"
  content  = local.syslog_client_conf
}

resource "local_file" "services_ship_conf" {
  count    = local.ship_logs ? 1 : 0
  filename = "${local.render_dir}/services-ship.conf"
  content  = local.syslog_client_conf
}

resource "local_file" "ca_otel_conf" {
  count    = local.push_otlp ? 1 : 0
  filename = "${local.render_dir}/ca-otel.yaml"
  content  = local.otel_agent_conf_ca
}

resource "local_file" "services_otel_conf" {
  count    = local.push_otlp ? 1 : 0
  filename = "${local.render_dir}/services-otel.yaml"
  content  = local.otel_agent_conf_services
}
