locals {
  # Explicit inline key wins; otherwise read the pubkey file if it exists; otherwise empty.
  ssh_pubkey = var.ssh_pubkey != "" ? var.ssh_pubkey : (
    fileexists(pathexpand(var.ssh_pubkey_path)) ? trimspace(file(pathexpand(var.ssh_pubkey_path))) : ""
  )

  render_dir = "${path.module}/.rendered"

  server_name = "${var.name_prefix}-server"
  client_name = "${var.name_prefix}-client"
  agent_name  = "${var.name_prefix}-agent"

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
    diode_metrics_port            = var.diode_metrics_port
    diode_tag                     = var.diode_tag
    redis_password                = var.diode_redis_password
    postgres_password             = var.diode_postgres_password
    hydra_system_secret           = var.diode_hydra_system_secret
    diode_to_netbox_client_secret = var.diode_to_netbox_client_secret
  })
  diode_compose = templatefile("${path.module}/cloud-init/diode/docker-compose.yaml.tftpl", {
    diode_tag          = var.diode_tag
    diode_port         = var.diode_port
    diode_metrics_port = var.diode_metrics_port
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
}

# --- NetBox server VM (netbox-docker stack) ---------------------------------

resource "local_file" "server_ci" {
  filename = "${local.render_dir}/server.yaml"
  content = templatefile("${path.module}/cloud-init/server.yaml.tftpl", {
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
    diode_metrics_port            = var.diode_metrics_port
    diode_plugin_version          = var.diode_plugin_version
    diode_to_netbox_client_secret = var.diode_to_netbox_client_secret
    netbox_to_diode_client_secret = var.netbox_to_diode_client_secret
    diode_env                     = local.diode_env
    diode_compose                 = local.diode_compose
    diode_credentials             = local.diode_credentials
    diode_nginx                   = local.diode_nginx
    plugin_requirements           = local.plugin_requirements
    plugin_config                 = local.plugin_config
  })
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
  content = templatefile("${path.module}/cloud-init/client.yaml.tftpl", {
    ssh_pubkey       = local.ssh_pubkey
    netbox_ip        = multipass_instance.server.ipv4
    netbox_port      = var.netbox_port
    netbox_api_token = var.netbox_api_token
    cluster_name     = var.cluster_name
    host_device_name = var.netbox_host_device_name
  })
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
