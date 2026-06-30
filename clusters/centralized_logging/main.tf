locals {
  # Explicit inline key wins; otherwise read the pubkey file if it exists; otherwise empty.
  ssh_pubkey = var.ssh_pubkey != "" ? var.ssh_pubkey : (
    fileexists(pathexpand(var.ssh_pubkey_path)) ? trimspace(file(pathexpand(var.ssh_pubkey_path))) : ""
  )

  render_dir = "${path.module}/.rendered"

  central_name = "${var.name_prefix}-central"
  k0s_name     = "${var.name_prefix}-k0s"
  docker_name  = "${var.name_prefix}-docker"

  # One map of every metrics enable_* flag, merged into every templatefile() call so
  # each cloud-init template renders its own %{ if enable_x ~}…%{ endif ~} install
  # blocks. A disabled flag is therefore neither installed nor running on the VM.
  # (Mirrors clusters/centralized_monitoring/main.tf.) No scrape is wired locally —
  # see specs/centralized_logging_metrics.md.
  flags = {
    enable_node_exporter      = var.enable_node_exporter
    enable_syslogng_metrics   = var.enable_syslogng_metrics
    enable_systemd_exporter   = var.enable_systemd_exporter
    enable_journald_exporter  = var.enable_journald_exporter
    enable_process_exporter   = var.enable_process_exporter
    enable_filestat_exporter  = var.enable_filestat_exporter
    enable_cadvisor           = var.enable_cadvisor
    enable_traefik_metrics    = var.enable_traefik_metrics
    enable_kube_metrics       = var.enable_kube_metrics
    enable_kube_state_metrics = var.enable_kube_state_metrics
  }

  # Sorted list of active flags — exported as enabled_exporters and consumed by
  # tests/testinfra/conftest.py so the live suite asserts only what is on.
  enabled_exporters = sort([for k, v in local.flags : k if v])

  # How central resolves $HOST for remote senders (see var.hostname_source).
  hostname_opts = {
    keep = "keep-hostname(yes)"
    dns  = "keep-hostname(no)\n        use-dns(yes)\n        use-fqdn(no)"
    ip   = "keep-hostname(no)\n        use-dns(no)"
  }[var.hostname_source]

  # syslog-ng server config (central is the sink).
  server_conf = templatefile("${path.module}/cloud-init/syslog-ng/server.conf.tftpl", {
    syslog_port   = var.syslog_port
    hostname_opts = local.hostname_opts
  })

  # Docker compose stack. Flags are threaded so Traefik's metrics endpoint renders
  # under %{ if enable_traefik_metrics ~}.
  compose_conf = templatefile("${path.module}/cloud-init/docker/compose.yaml.tftpl", local.flags)

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
  content = templatefile("${path.module}/cloud-init/central.yaml.tftpl", merge(local.flags, {
    ssh_pubkey  = local.ssh_pubkey
    server_conf = local.server_conf
  }))
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
  content = templatefile("${path.module}/cloud-init/k0s-client.yaml.tftpl", merge(local.flags, {
    ssh_pubkey  = local.ssh_pubkey
    client_conf = local.client_conf
  }))
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
  content = templatefile("${path.module}/cloud-init/docker-client.yaml.tftpl", merge(local.flags, {
    ssh_pubkey   = local.ssh_pubkey
    client_conf  = local.client_conf
    compose_conf = local.compose_conf
  }))
}

resource "multipass_instance" "docker" {
  name           = local.docker_name
  image          = var.image
  cpus           = var.docker_client.cpus
  memory         = var.docker_client.memory
  disk           = var.docker_client.disk
  cloudinit_file = local_file.docker_ci.filename
}
