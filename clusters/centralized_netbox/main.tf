locals {
  # Explicit inline key wins; otherwise read the pubkey file if it exists; otherwise empty.
  ssh_pubkey = var.ssh_pubkey != "" ? var.ssh_pubkey : (
    fileexists(pathexpand(var.ssh_pubkey_path)) ? trimspace(file(pathexpand(var.ssh_pubkey_path))) : ""
  )

  render_dir = "${path.module}/.rendered"

  server_name = "${var.name_prefix}-server"
  client_name = "${var.name_prefix}-client"

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
    netbox_port = var.netbox_port
  })

  # Opt-in feature flags, merged into every templatefile() call so each cloud-init template
  # renders its own %{ if enable_x ~}…%{ endif ~} blocks. Mirrors the centralized_logging /
  # centralized_monitoring clusters. Surfaced via the enabled_features output so the live
  # suite skips (not fails) a disabled feature. No local Prometheus here — dashboard-only.
  flags = {
    enable_netdata = var.enable_netdata
  }

  # tests/testinfra/conftest.py reads this so a disabled feature is skipped, not failed.
  enabled_features = { for k, v in local.flags : replace(k, "enable_", "") => v }
}

# --- NetBox server VM (netbox-docker stack) ---------------------------------

resource "local_file" "server_ci" {
  filename = "${local.render_dir}/server.yaml"
  content = templatefile("${path.module}/cloud-init/server.yaml.tftpl", merge(local.flags, {
    ssh_pubkey         = local.ssh_pubkey
    override_conf      = local.override_conf
    netbox_port        = var.netbox_port
    netbox_api_token   = var.netbox_api_token
    netbox_docker_ref  = var.netbox_docker_ref
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
