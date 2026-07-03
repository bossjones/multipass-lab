locals {
  # Explicit inline key wins; otherwise read the pubkey file if it exists; otherwise empty.
  ssh_pubkey = var.ssh_pubkey != "" ? var.ssh_pubkey : (
    fileexists(pathexpand(var.ssh_pubkey_path)) ? trimspace(file(pathexpand(var.ssh_pubkey_path))) : ""
  )

  render_dir = "${path.module}/.rendered"

  controller_name = "${var.name_prefix}-controller"
  usg_name        = "${var.name_prefix}-usg"

  exact = var.version_mode == "exact"

  # One map merged into every templatefile() so each cloud-init renders its own
  # %{ if ... ~}…%{ endif ~} blocks (mirrors clusters/centralized_logging/main.tf).
  flags = {
    exact                    = local.exact
    version_mode             = var.version_mode
    enable_node_exporter     = var.enable_node_exporter
    enable_syslogng_exporter = var.enable_syslogng_exporter
    enable_unifi_traffic     = var.enable_unifi_traffic
    syslogng_deb_version     = var.syslogng_deb_version
    rsyslog_deb_version      = var.rsyslog_deb_version
    controller_base_image    = var.controller_base_image
    usg_base_image           = var.usg_base_image
    usg_platform             = var.usg_platform
    syslog_port              = var.syslog_port
  }

  # Sorted list of active exporter flags — exported as enabled_exporters and consumed by
  # tests/testinfra/conftest.py so the live suite asserts only what is on.
  enabled_exporters = sort([for k, v in {
    node     = var.enable_node_exporter
    syslogng = var.enable_syslogng_exporter
  } : k if v])

  # --- Controller (UCK / syslog-ng) container assets ------------------------

  # syslog-ng 3.28.1 (UCK persona) config: the appliance conf.d fan-out + not2msg inlined,
  # PLUS a network() collector source + d_remote file sink + raised stats level for the exporter.
  uck_conf = templatefile("${path.module}/cloud-init/controller/uck.conf.tftpl", {
    syslog_port = var.syslog_port
  })

  controller_dockerfile = templatefile("${path.module}/cloud-init/controller/Dockerfile.syslogng.tftpl", {
    controller_base_image = var.controller_base_image
    syslogng_deb_version  = var.syslogng_deb_version
  })

  controller_compose = templatefile("${path.module}/cloud-init/controller/compose.yaml.tftpl", {
    enable_syslogng_exporter = var.enable_syslogng_exporter
  })

  # --- USG (rsyslog) container assets ---------------------------------------

  usg_dockerfile = templatefile("${path.module}/cloud-init/usg/Dockerfile.rsyslog.tftpl", {
    usg_base_image = var.usg_base_image
    usg_platform   = var.usg_platform
  })

  usg_compose = templatefile("${path.module}/cloud-init/usg/compose.yaml.tftpl", {
    usg_platform         = var.usg_platform
    enable_unifi_traffic = var.enable_unifi_traffic
  })

  # rsyslog base config (USG persona) — verbatim from the appliance; static file.
  usg_rsyslog_conf = file("${path.module}/cloud-init/usg/rsyslog.conf")
  usg_gen_script   = file("${path.module}/cloud-init/usg/unifi-gen.sh")
  usg_entrypoint   = file("${path.module}/cloud-init/usg/entrypoint.sh")

  # USG's Vyatta forward rule — references the controller's runtime IP, which forces OpenTofu
  # to create `controller` (and learn its ipv4) before rendering/launching the USG VM.
  vyatta_conf = templatefile("${path.module}/cloud-init/usg/vyatta.conf.tftpl", {
    controller_ip = multipass_instance.controller.ipv4
    syslog_port   = var.syslog_port
  })
}

# --- Controller VM (syslog-ng collector + exporter) -------------------------

resource "local_file" "controller_ci" {
  filename = "${local.render_dir}/controller.yaml"
  content = templatefile("${path.module}/cloud-init/controller.yaml.tftpl", merge(local.flags, {
    ssh_pubkey            = local.ssh_pubkey
    uck_conf              = local.uck_conf
    controller_dockerfile = local.controller_dockerfile
    controller_compose    = local.controller_compose
  }))
}

resource "multipass_instance" "controller" {
  name           = local.controller_name
  image          = var.image
  cpus           = var.controller.cpus
  memory         = var.controller.memory
  disk           = var.controller.disk
  cloudinit_file = local_file.controller_ci.filename
}

# --- USG VM (rsyslog forwarder + traffic generator) -------------------------

resource "local_file" "usg_ci" {
  filename = "${local.render_dir}/usg.yaml"
  content = templatefile("${path.module}/cloud-init/usg.yaml.tftpl", merge(local.flags, {
    ssh_pubkey        = local.ssh_pubkey
    usg_dockerfile    = local.usg_dockerfile
    usg_compose       = local.usg_compose
    rsyslog_conf      = local.usg_rsyslog_conf
    vyatta_conf       = local.vyatta_conf
    gen_script        = local.usg_gen_script
    entrypoint_script = local.usg_entrypoint
  }))
}

resource "multipass_instance" "usg" {
  name           = local.usg_name
  image          = var.image
  cpus           = var.usg.cpus
  memory         = var.usg.memory
  disk           = var.usg.disk
  cloudinit_file = local_file.usg_ci.filename
}
