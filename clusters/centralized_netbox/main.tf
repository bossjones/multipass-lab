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

  # netbox-docker override: publish :8000 -> container :8080 and skip the image's own superuser
  # creation (netbox-stack.sh does it). Rendered once and spliced into the server cloud-init.
  override_conf = templatefile("${path.module}/cloud-init/netbox/docker-compose.override.yml.tftpl", {
    netbox_port = var.netbox_port
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
    netbox_docker_ref  = var.netbox_docker_ref
    superuser_name     = var.netbox_superuser_name
    superuser_password = var.netbox_superuser_password
    cluster_type       = var.cluster_type
    cluster_type_slug  = local.cluster_type_slug
    cluster_name       = var.cluster_name
    site_name          = var.site_name
    site_slug          = local.site_slug
  })
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
  content = templatefile("${path.module}/cloud-init/client.yaml.tftpl", {
    ssh_pubkey       = local.ssh_pubkey
    netbox_ip        = multipass_instance.server.ipv4
    netbox_port      = var.netbox_port
    netbox_api_token = var.netbox_api_token
    cluster_name     = var.cluster_name
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
