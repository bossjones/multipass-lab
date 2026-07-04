locals {
  # Explicit inline key wins; otherwise read the pubkey file if it exists; otherwise empty.
  ssh_pubkey = var.ssh_pubkey != "" ? var.ssh_pubkey : (
    fileexists(pathexpand(var.ssh_pubkey_path)) ? trimspace(file(pathexpand(var.ssh_pubkey_path))) : ""
  )

  render_dir = "${path.module}/.rendered"

  # Interactive docker tooling installer (wharf/oxker/dive), shared byte-identically across
  # every cluster with a docker VM. Static script → file() (no templating); embedded into the
  # server + discovery-agent cloud-inits via write_files and run under enable_docker_tools
  # (the client VM has no docker, so it is left out).
  docker_tools_installer = file("${path.module}/../_shared/cloud-init/install-docker-tools.sh")

  server_name = "${var.name_prefix}-server"
  client_name = "${var.name_prefix}-client"
  agent_name  = "${var.name_prefix}-agent"

  # --- Cross-cluster DNS (opt-in; see specs/cross-cluster.md) ---------------
  # Rendered from the SHARED clusters/_shared/cloud-init/use-dns.conf.tftpl only when dns_server is
  # set; empty string otherwise so each VM's cloud-init %{ if dns_server != "" } guard drops the
  # block. Only the host portion is used (systemd-resolved DNS= takes an IP); a host:port target has
  # the port dropped.
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

  # --- discovery (opt-in Diode + orb-agent) --------------------------------
  # enable_discovery bumps NetBox to a 4.4.x pin (keeps pinnable v1 tokens AND satisfies Diode's
  # >= 4.2.3 requirement) and auto-bumps the server (netbox-docker + the ~9-container Diode stack
  # is heavy), exactly like centralized_logging auto-bumps the k0s node for Coroot. See
  # specs/netbox-discovery.md.
  effective_netbox_ref = var.enable_discovery ? var.netbox_docker_ref_discovery : var.netbox_docker_ref

  server_size = var.enable_discovery ? {
    cpus   = 6
    memory = "10G"
    disk   = "50G"
  } : var.server

  # Multipass /24 the server sits on, derived from its (runtime) IP; try() keeps hermetic
  # mock-provider plans from erroring on a non-IP-shaped mock value (mirrors outputs.tf).
  server_subnet = try("${join(".", slice(split(".", multipass_instance.server.ipv4), 0, 3))}.0/24", "10.0.0.0/24")

  # Rendered Diode server + plugin config, spliced into the server cloud-init's write_files under a
  # `%{ if enable_discovery }` guard. Always computed (so the server templatefile always has these
  # vars defined) but only written when discovery is on. The server's own runtime IP is substituted
  # for the __SERVER_IP__ placeholder by netbox-stack.sh (Diode + NetBox reach each other over the
  # host IP since they are separate compose projects).
  diode_env = templatefile("${path.module}/cloud-init/diode/env.tftpl", {
    netbox_port                   = var.netbox_port
    diode_port                    = var.diode_port
    diode_tag                     = var.diode_tag
    redis_password                = var.diode_redis_password
    postgres_password             = var.diode_postgres_password
    hydra_system_secret           = var.diode_hydra_system_secret
    diode_to_netbox_client_secret = var.diode_to_netbox_client_secret
  })
  # The compose file is byte-for-byte the upstream release (values flow from .env via compose
  # ${VAR} interpolation), so templatefile gets no Tofu vars — see docker-compose.yaml.tftpl.
  diode_compose = templatefile("${path.module}/cloud-init/diode/docker-compose.yaml.tftpl", {})
  # Multi-DB initdb script (creates the diode + hydra databases) — the fix for stock postgres
  # ignoring POSTGRES_MULTIPLE_DATABASES. Rendered with the pinned lab postgres password.
  diode_postgres_init = templatefile("${path.module}/cloud-init/diode/postgres-init.sh.tftpl", {
    postgres_password = var.diode_postgres_password
  })
  diode_credentials = templatefile("${path.module}/cloud-init/diode/client-credentials.json.tftpl", {
    diode_ingest_client_secret    = var.diode_ingest_client_secret
    diode_to_netbox_client_secret = var.diode_to_netbox_client_secret
    netbox_to_diode_client_secret = var.netbox_to_diode_client_secret
  })
  diode_nginx         = templatefile("${path.module}/cloud-init/diode/nginx.conf.tftpl", {})
  plugin_requirements = templatefile("${path.module}/cloud-init/netbox/plugin_requirements.txt.tftpl", { diode_plugin_version = var.diode_plugin_version })
  plugin_config = templatefile("${path.module}/cloud-init/netbox/plugins.py.tftpl", {
    diode_port                    = var.diode_port
    netbox_to_diode_client_secret = var.netbox_to_diode_client_secret
  })

  # orb-agent policy YAML for the discovery agent VM. The server IP is known at render time
  # (multipass_instance.server.ipv4), so the agent's Diode target + scan scope are baked directly.
  orb_config = templatefile("${path.module}/cloud-init/orb/agent.yaml.tftpl", {
    netbox_ip                  = multipass_instance.server.ipv4
    diode_port                 = var.diode_port
    server_subnet              = local.server_subnet
    diode_ingest_client_secret = var.diode_ingest_client_secret
  })

  # NetBox requires a slug for a cluster-type and a site; derive them from the human names.
  cluster_type_slug = lower(replace(var.cluster_type, " ", "-"))
  site_slug         = lower(replace(var.site_name, " ", "-"))

  # Slugs for the base data-model seed (see specs/netbox-data.md).
  region_slug            = lower(replace(var.netbox_region, " ", "-"))
  site_group_slug        = lower(replace(var.netbox_site_group, " ", "-"))
  location_slug          = lower(replace(var.netbox_location, " ", "-"))
  tenant_slug            = lower(replace(var.netbox_tenant, " ", "-"))
  host_manufacturer_slug = lower(replace(var.netbox_host_manufacturer, " ", "-"))
  host_model_slug        = lower(replace(var.netbox_host_model, " ", "-"))

  # netbox-docker override: publish :8000 -> container :8080 and skip the image's own superuser
  # creation (netbox-stack.sh does it). Rendered once and spliced into the server cloud-init.
  override_conf = templatefile("${path.module}/cloud-init/netbox/docker-compose.override.yml.tftpl", {
    netbox_port      = var.netbox_port
    enable_discovery = var.enable_discovery
  })

  # Opt-in feature flags, merged into every templatefile() call so each cloud-init template
  # renders its own %{ if enable_x ~}…%{ endif ~} blocks. Mirrors the centralized_logging /
  # centralized_monitoring clusters.
  flags = {
    enable_netdata          = var.enable_netdata
    enable_node_exporter    = var.enable_node_exporter
    enable_process_exporter = var.enable_process_exporter
    enable_systemd_exporter = var.enable_systemd_exporter
  }

  # tests/testinfra/conftest.py reads this so a disabled feature is skipped, not failed.
  enabled_features = { netdata = var.enable_netdata }

  # Netdata agent installer (shared snippet), rendered per-VM so [host labels] carry this VM's
  # cluster+role (they ride on netdata_info{...}). Empty when disabled -> the %{ if enable_netdata }
  # write_files/runcmd guards drop the block. See specs/shared-netdata.md.
  netdata_installer_server = var.enable_netdata ? templatefile("${path.module}/../_shared/cloud-init/install-netdata.sh.tftpl", {
    host_labels = { cluster = var.name_prefix, role = "server", environment = "lab" }
    enable_ebpf = var.enable_netdata_ebpf
  }) : ""
  netdata_installer_client = var.enable_netdata ? templatefile("${path.module}/../_shared/cloud-init/install-netdata.sh.tftpl", {
    host_labels = { cluster = var.name_prefix, role = "client", environment = "lab" }
    enable_ebpf = var.enable_netdata_ebpf
  }) : ""
  netdata_installer_agent = var.enable_netdata ? templatefile("${path.module}/../_shared/cloud-init/install-netdata.sh.tftpl", {
    host_labels = { cluster = var.name_prefix, role = "agent", environment = "lab" }
    enable_ebpf = var.enable_netdata_ebpf
  }) : ""

  # Sorted list of active exporter flags — exported as enabled_exporters and consumed by
  # tests/testinfra. Kept disjoint from enabled_features so this doesn't also list netdata.
  enabled_exporters = sort([
    for k, v in {
      enable_node_exporter    = var.enable_node_exporter
      enable_process_exporter = var.enable_process_exporter
      enable_systemd_exporter = var.enable_systemd_exporter
    } : k if v
  ])
}

# --- NetBox server VM (netbox-docker stack) ---------------------------------

resource "local_file" "server_ci" {
  filename = "${local.render_dir}/server.yaml"
  content = templatefile("${path.module}/cloud-init/server.yaml.tftpl", merge(local.flags, {
    ssh_pubkey         = local.ssh_pubkey
    override_conf      = local.override_conf
    netbox_port        = var.netbox_port
    netbox_api_token   = var.netbox_api_token
    netbox_docker_ref  = local.effective_netbox_ref
    superuser_name     = var.netbox_superuser_name
    superuser_password = var.netbox_superuser_password
    cluster_type       = var.cluster_type
    cluster_type_slug  = local.cluster_type_slug
    cluster_name       = var.cluster_name
    site_name          = var.site_name
    site_slug          = local.site_slug
    server_name        = local.server_name
    # base data-model seed
    region                 = var.netbox_region
    region_slug            = local.region_slug
    site_group             = var.netbox_site_group
    site_group_slug        = local.site_group_slug
    location               = var.netbox_location
    location_slug          = local.location_slug
    tenant                 = var.netbox_tenant
    tenant_slug            = local.tenant_slug
    rack_name              = var.netbox_rack_name
    host_device_name       = var.netbox_host_device_name
    host_manufacturer      = var.netbox_host_manufacturer
    host_manufacturer_slug = local.host_manufacturer_slug
    host_model             = var.netbox_host_model
    host_model_slug        = local.host_model_slug
    # discovery (opt-in) — the server templatefile always receives these; the `%{ if
    # enable_discovery }` blocks decide whether they are written. See specs/netbox-discovery.md.
    enable_discovery              = var.enable_discovery
    diode_port                    = var.diode_port
    diode_plugin_version          = var.diode_plugin_version
    diode_to_netbox_client_secret = var.diode_to_netbox_client_secret
    netbox_to_diode_client_secret = var.netbox_to_diode_client_secret
    diode_env                     = local.diode_env
    diode_compose                 = local.diode_compose
    diode_postgres_init           = local.diode_postgres_init
    diode_credentials             = local.diode_credentials
    diode_nginx                   = local.diode_nginx
    plugin_requirements           = local.plugin_requirements
    plugin_config                 = local.plugin_config
    # Cross-cluster DNS (opt-in) — point systemd-resolved at the centralized_dns hub.
    dns_server        = var.dns_server
    dns_resolved_conf = local.dns_resolved_conf
    internal_ca_cert  = var.internal_ca_cert
    ntp_timesync      = local.ntp_timesync
    ntp_server        = var.ntp_server
    ntp_conf          = local.ntp_conf
    # Docker operator TUIs (wharf/oxker/dive) — the server runs the netbox-docker stack.
    enable_docker_tools    = var.enable_docker_tools
    docker_tools_installer = local.docker_tools_installer
    # Netdata agent (:19999) — installed by the shared snippet. enable_netdata rides in local.flags.
    netdata_installer = local.netdata_installer_server
  }))
}

resource "multipass_instance" "server" {
  name           = local.server_name
  image          = var.image
  cpus           = local.server_size.cpus
  memory         = local.server_size.memory
  disk           = local.server_size.disk
  cloudinit_file = local_file.server_ci.filename
}

# --- Self-registering client VM ---------------------------------------------
# The client cloud-init references the server's runtime IP, which forces OpenTofu to create the
# server (and learn its DHCP ipv4) before rendering/launching the client — the same runtime
# IP-injection edge centralized_logging uses for its syslog-ng client_conf.

resource "local_file" "client_ci" {
  filename = "${local.render_dir}/client.yaml"
  content = templatefile("${path.module}/cloud-init/client.yaml.tftpl", merge(local.flags, {
    ssh_pubkey       = local.ssh_pubkey
    netbox_ip        = multipass_instance.server.ipv4
    netbox_port      = var.netbox_port
    netbox_api_token = var.netbox_api_token
    cluster_name     = var.cluster_name
    host_device_name = var.netbox_host_device_name
    # Cross-cluster DNS (opt-in) — point systemd-resolved at the centralized_dns hub.
    dns_server        = var.dns_server
    dns_resolved_conf = local.dns_resolved_conf
    internal_ca_cert  = var.internal_ca_cert
    ntp_timesync      = local.ntp_timesync
    ntp_server        = var.ntp_server
    ntp_conf          = local.ntp_conf
    # Netdata agent (:19999) — installed by the shared snippet. enable_netdata rides in local.flags.
    netdata_installer = local.netdata_installer_client
  }))
}

resource "multipass_instance" "client" {
  name           = local.client_name
  image          = var.image
  cpus           = var.client.cpus
  memory         = var.client.memory
  disk           = var.client.disk
  cloudinit_file = local_file.client_ci.filename
}

# --- Discovery agent VM (opt-in) --------------------------------------------
# Only created when enable_discovery. Runs netboxlabs/orb-agent (--net=host) to scan the Multipass
# /24 via network_discovery (nmap) and ingest discovered IPs/hosts into Diode over gRPC. Like the
# client, it references the server's runtime IP (baked into its Diode target + orb config), which
# orders it after the server in the same apply. See specs/netbox-discovery.md.

resource "local_file" "agent_ci" {
  count    = var.enable_discovery ? 1 : 0
  filename = "${local.render_dir}/agent.yaml"
  content = templatefile("${path.module}/cloud-init/agent.yaml.tftpl", {
    ssh_pubkey                 = local.ssh_pubkey
    netbox_ip                  = multipass_instance.server.ipv4
    diode_port                 = var.diode_port
    orb_agent_image            = var.orb_agent_image
    diode_ingest_client_secret = var.diode_ingest_client_secret
    orb_config                 = local.orb_config
    # Cross-cluster DNS (opt-in) — point systemd-resolved at the centralized_dns hub.
    dns_server        = var.dns_server
    dns_resolved_conf = local.dns_resolved_conf
    internal_ca_cert  = var.internal_ca_cert
    ntp_timesync      = local.ntp_timesync
    ntp_server        = var.ntp_server
    ntp_conf          = local.ntp_conf
    # Docker operator TUIs (wharf/oxker/dive) — the agent runs orb-agent via docker.
    enable_docker_tools    = var.enable_docker_tools
    docker_tools_installer = local.docker_tools_installer
    # node_exporter (:9100) — parity with the client/server VMs. The cross-cluster scrape logic
    # adds every VM (incl. this agent) as a :9100 target, so without it the agent chronically
    # reports TargetDown. Threaded in explicitly (this templatefile does not merge local.flags).
    enable_node_exporter = var.enable_node_exporter
    # Netdata agent (:19999) — installed by the shared snippet (this VM's templatefile does not
    # merge local.flags, so enable_netdata is threaded in explicitly alongside the installer).
    enable_netdata    = var.enable_netdata
    netdata_installer = local.netdata_installer_agent
  })
}

resource "multipass_instance" "agent" {
  count          = var.enable_discovery ? 1 : 0
  name           = local.agent_name
  image          = var.image
  cpus           = var.agent.cpus
  memory         = var.agent.memory
  disk           = var.agent.disk
  cloudinit_file = local_file.agent_ci[0].filename
}

# --- Hot-push artifacts (see specs/cross-cluster.md; `just refresh-cross-cluster`) ---
# Discrete per-VM renders of the DNS resolver drop-in, so a centralized_dns IP change can be
# scp'd onto an already-running VM (content-only tofu apply, no recreate) instead of a reprovision.
resource "local_file" "server_resolved_conf" {
  count    = local.use_dns ? 1 : 0
  filename = "${local.render_dir}/server-resolved.conf"
  content  = local.dns_resolved_conf
}

resource "local_file" "client_resolved_conf" {
  count    = local.use_dns ? 1 : 0
  filename = "${local.render_dir}/client-resolved.conf"
  content  = local.dns_resolved_conf
}

resource "local_file" "agent_resolved_conf" {
  count    = local.use_dns && var.enable_discovery ? 1 : 0
  filename = "${local.render_dir}/agent-resolved.conf"
  content  = local.dns_resolved_conf
}

# Internal NTP source drop-in, rendered standalone per-VM for scp onto a running VM by
# `just refresh-cross-cluster` (mirrors the resolved.conf hot-push above). See specs/shared-ntp.md.
resource "local_file" "server_ntp_conf" {
  count    = local.use_ntp ? 1 : 0
  filename = "${local.render_dir}/server-ntp.conf"
  content  = local.ntp_conf
}

resource "local_file" "client_ntp_conf" {
  count    = local.use_ntp ? 1 : 0
  filename = "${local.render_dir}/client-ntp.conf"
  content  = local.ntp_conf
}

resource "local_file" "agent_ntp_conf" {
  count    = local.use_ntp && var.enable_discovery ? 1 : 0
  filename = "${local.render_dir}/agent-ntp.conf"
  content  = local.ntp_conf
}
