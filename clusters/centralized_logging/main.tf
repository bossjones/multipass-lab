locals {
  # Explicit inline key wins; otherwise read the pubkey file if it exists; otherwise empty.
  ssh_pubkey = var.ssh_pubkey != "" ? var.ssh_pubkey : (
    fileexists(pathexpand(var.ssh_pubkey_path)) ? trimspace(file(pathexpand(var.ssh_pubkey_path))) : ""
  )

  render_dir = "${path.module}/.rendered"

  central_name = "${var.name_prefix}-central"
  k0s_name     = "${var.name_prefix}-k0s"
  docker_name  = "${var.name_prefix}-docker"

  # syslog-ng server config (static — central is the sink).
  server_conf = templatefile("${path.module}/cloud-init/syslog-ng/server.conf.tftpl", {
    syslog_port = var.syslog_port
  })

  # Docker compose stack (no dynamic inputs).
  compose_conf = templatefile("${path.module}/cloud-init/docker/compose.yaml.tftpl", {})

  # syslog-ng client config — references the central VM's runtime IP, which forces
  # OpenTofu to create `central` (and learn its ipv4) before rendering/launching clients.
  client_conf = templatefile("${path.module}/cloud-init/syslog-ng/client.conf.tftpl", {
    central_ip  = multipass_instance.central.ipv4
    syslog_port = var.syslog_port
  })
}

# --- Central logging VM (syslog-ng server) ----------------------------------

resource "local_file" "central_ci" {
  filename = "${local.render_dir}/central.yaml"
  content = templatefile("${path.module}/cloud-init/central.yaml.tftpl", {
    ssh_pubkey  = local.ssh_pubkey
    server_conf = local.server_conf
  })
}

resource "multipass_instance" "central" {
  name           = local.central_name
  image          = var.image
  cpus           = var.central.cpus
  memory         = var.central.memory
  disk           = var.central.disk
  cloudinit_file = local_file.central_ci.filename
}

# --- k0s single-node client -------------------------------------------------

resource "local_file" "k0s_ci" {
  filename = "${local.render_dir}/k0s-client.yaml"
  content = templatefile("${path.module}/cloud-init/k0s-client.yaml.tftpl", {
    ssh_pubkey  = local.ssh_pubkey
    client_conf = local.client_conf
  })
}

resource "multipass_instance" "k0s" {
  name           = local.k0s_name
  image          = var.image
  cpus           = var.k0s_client.cpus
  memory         = var.k0s_client.memory
  disk           = var.k0s_client.disk
  cloudinit_file = local_file.k0s_ci.filename
}

# --- Docker stack client ----------------------------------------------------

resource "local_file" "docker_ci" {
  filename = "${local.render_dir}/docker-client.yaml"
  content = templatefile("${path.module}/cloud-init/docker-client.yaml.tftpl", {
    ssh_pubkey   = local.ssh_pubkey
    client_conf  = local.client_conf
    compose_conf = local.compose_conf
  })
}

resource "multipass_instance" "docker" {
  name           = local.docker_name
  image          = var.image
  cpus           = var.docker_client.cpus
  memory         = var.docker_client.memory
  disk           = var.docker_client.disk
  cloudinit_file = local_file.docker_ci.filename
}
