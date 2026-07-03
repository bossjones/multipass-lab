locals {
  # Explicit inline key wins; otherwise read the pubkey file if it exists; otherwise empty.
  ssh_pubkey = var.ssh_pubkey != "" ? var.ssh_pubkey : (
    fileexists(pathexpand(var.ssh_pubkey_path)) ? trimspace(file(pathexpand(var.ssh_pubkey_path))) : ""
  )

  render_dir = "${path.module}/.rendered"

  # Interactive docker tooling installer (wharf/oxker/dive), shared byte-identically across
  # every cluster with a docker VM. Static script → file() (no templating); embedded into the
  # server cloud-init via write_files and run under enable_docker_tools.
  docker_tools_installer = file("${path.module}/../_shared/cloud-init/install-docker-tools.sh")

  # multipass exec/transfer don't route to VMs in this environment (see CLAUDE.md); every
  # post-apply VM touch goes over SSH instead, using the same key injected via cloud-init.
  ssh_private_key = trimsuffix(pathexpand(var.ssh_pubkey_path), ".pub")
  ssh_opts        = "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8 -i ${local.ssh_private_key}"

  server_name = "${var.name_prefix}-server"
  k0s_name    = "${var.name_prefix}-k0s"

  # OpenObserve rejects weak passwords; this dedicated strong value is used both for the
  # OpenObserve root user and the Grafana OpenObserve-datasource basic auth (must match).
  openobserve_password = "Complexpass#123"

  # OpenObserve organization every ingest/query path targets (root user's built-in org).
  # Threaded into prometheus.yml remote_write, the OTel exporter endpoint, and the k0s agent.
  openobserve_org = "default"

  # k0s log-shipping agent config, rendered with a 127.0.0.1 PLACEHOLDER endpoint and baked
  # into the k0s cloud-init (the k0s VM boots before the server, so its IP is unknown here).
  # terraform_data.k0s_log_shipper re-renders it with the real server IP and pushes it post-apply.
  k0s_otel_placeholder = templatefile("${path.module}/cloud-init/otel/k0s-collector-config.yaml.tftpl", {
    server_ip            = "127.0.0.1"
    openobserve_org      = local.openobserve_org
    openobserve_password = local.openobserve_password
  })

  # One map of every enable_* flag, threaded into every templatefile() call so each
  # template renders its own %{ if enable_x ~}…%{ endif ~} blocks. A disabled flag is
  # therefore neither installed/composed on the VM nor scraped by Prometheus.
  flags = {
    # MVP
    enable_otel             = var.enable_otel
    enable_openobserve      = var.enable_openobserve
    enable_k0s_log_shipping = var.enable_k0s_log_shipping
    enable_blackbox         = var.enable_blackbox
    enable_node_exporter    = var.enable_node_exporter
    enable_cadvisor         = var.enable_cadvisor
    enable_process_exporter = var.enable_process_exporter
    enable_systemd_exporter = var.enable_systemd_exporter
    enable_netdata          = var.enable_netdata
    # Reach
    enable_kube_state_metrics = var.enable_kube_state_metrics
    enable_kubelet_scrape     = var.enable_kubelet_scrape
    enable_heimdall           = var.enable_heimdall
    enable_uptime_kuma        = var.enable_uptime_kuma
    enable_traefik            = var.enable_traefik
    enable_nut_exporter       = var.enable_nut_exporter
    enable_nftables_exporter  = var.enable_nftables_exporter
    enable_statsd_exporter    = var.enable_statsd_exporter
    enable_ssh_exporter       = var.enable_ssh_exporter
    enable_filestat_exporter  = var.enable_filestat_exporter
    # Nice-to-have
    enable_osquery_exporter = var.enable_osquery_exporter
    enable_ebpf_exporter    = var.enable_ebpf_exporter
    enable_texporter        = var.enable_texporter
    enable_ffmpeg_exporter  = var.enable_ffmpeg_exporter
    enable_script_exporter  = var.enable_script_exporter
    enable_vector           = var.enable_vector
  }

  # Sorted list of the active flags — exported as enabled_exporters and consumed by
  # tests/testinfra/conftest.py so the live suite asserts only what is on.
  enabled_exporters = sort([for k, v in local.flags : k if v])

  # --- Cross-cluster log shipping (opt-in; see specs/cross-cluster.md) -------
  # The monitoring hub is applied AFTER the logging hub in `just up-connected`, so the collector
  # IP is known at first boot — the server can render the SHARED syslog-ng client drop-in and ship
  # its own OS logs. Empty target => empty string so the cloud-init %{ if ... != "" } guard drops
  # the block. host:port is split; the port defaults if the target omits it.
  ship_logs = var.log_shipping_target != ""

  syslog_client_conf = local.ship_logs ? templatefile("${path.module}/../_shared/cloud-init/syslog-client.conf.tftpl", {
    central_ip  = split(":", var.log_shipping_target)[0]
    syslog_port = try(split(":", var.log_shipping_target)[1], "514")
  }) : ""

  # --- Cross-cluster DNS (opt-in; see specs/cross-cluster.md) -----------------
  # Non-empty dns_server => every VM renders the SHARED systemd-resolved drop-in and points its
  # stub resolver at the centralized_dns AdGuard Home hub. Empty => empty string so the cloud-init
  # %{ if ... != "" } guard drops the block. Only the IP portion (before an optional :port) is used.
  use_dns = var.dns_server != ""
  dns_resolved_conf = local.use_dns ? templatefile("${path.module}/../_shared/cloud-init/use-dns.conf.tftpl", {
    dns_ip = split(":", var.dns_server)[0]
  }) : ""
}

# --- k0s-client (the monitored host) — created FIRST ------------------------
# Prometheus pulls, so the dependency edge is the inverse of the logging cluster:
# the scrape target must exist (and have a DHCP IP) before the server renders.

resource "local_file" "k0s_ci" {
  filename = "${local.render_dir}/k0s-client.yaml"
  content = templatefile("${path.module}/cloud-init/k0s-client.yaml.tftpl", merge(local.flags, {
    ssh_pubkey      = local.ssh_pubkey
    k0s_otel_config = local.k0s_otel_placeholder
    # Cross-cluster DNS — gated on a non-empty dns_server. See specs/cross-cluster.md.
    dns_server        = var.dns_server
    dns_resolved_conf = local.dns_resolved_conf
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

# --- rendered server-side configs -------------------------------------------
# prometheus.yml references the k0s runtime IP — THIS is the edge that forces
# server-after-client ordering inside a single `tofu apply`:
#   server -> local_file.server_ci -> prometheus_yml -> k0s.ipv4 -> k0s instance.

locals {
  prometheus_yml = templatefile("${path.module}/cloud-init/prometheus/prometheus.yml.tftpl", merge(local.flags, {
    k0s_ip               = multipass_instance.k0s.ipv4
    scrape_interval      = var.prometheus_scrape_interval
    openobserve_org      = local.openobserve_org
    openobserve_password = local.openobserve_password
    # Cross-cluster scrape targets (VMs in OTHER clusters). Populated by `just up-connected`
    # via .cross-cluster.auto.tfvars.json; empty by default. See specs/cross-cluster.md.
    extra_scrape_targets = var.extra_scrape_targets
  }))

  compose_conf = templatefile("${path.module}/cloud-init/docker/compose.yaml.tftpl", merge(local.flags, {
    grafana_admin_password = var.grafana_admin_password
    openobserve_password   = local.openobserve_password
  }))

  grafana_datasources = templatefile("${path.module}/cloud-init/grafana/provisioning/datasources/datasources.yaml.tftpl", merge(local.flags, {
    openobserve_password = local.openobserve_password
  }))

  # OTel Collector config is templated so the OpenObserve auth token + org are injected
  # (rendered filelog receivers ship the server's container + host logs to OpenObserve).
  otel_config = templatefile("${path.module}/cloud-init/otel/collector-config.yaml.tftpl", merge(local.flags, {
    openobserve_org      = local.openobserve_org
    openobserve_password = local.openobserve_password
  }))

  # Static (non-templated) configs spliced verbatim into the server cloud-init.
  alert_rules       = file("${path.module}/cloud-init/prometheus/alert.rules.yml")
  blackbox_yml      = file("${path.module}/cloud-init/prometheus/blackbox.yml")
  alertmanager_yml  = file("${path.module}/cloud-init/alertmanager/alertmanager.yml")
  grafana_dash_prov = file("${path.module}/cloud-init/grafana/provisioning/dashboards/dashboards.yaml")
  ssh_exporter_conf = file("${path.module}/cloud-init/ssh/ssh_exporter.yaml")

  # Drop-a-file dashboard provisioning: every *.json under cloud-init/grafana/dashboards
  # (any depth) is swept and written to /var/lib/grafana/dashboards/<relpath> on the VM,
  # preserving the subdirectory so foldersFromFilesStructure files it into that Grafana
  # folder. Adding a dashboard needs no edit here — just drop the JSON. See specs/dashboards.md.
  grafana_dashboard_dir   = "${path.module}/cloud-init/grafana/dashboards"
  grafana_dashboard_files = fileset(local.grafana_dashboard_dir, "**/*.json")
  grafana_dashboards = [for f in local.grafana_dashboard_files : {
    name    = f
    content = file("${local.grafana_dashboard_dir}/${f}")
  }]

  # OpenObserve dashboards: same drop-a-file sweep as Grafana, but imported post-boot over the
  # REST API by openobserve-provision.sh (OpenObserve has no file-provisioning; see the script +
  # specs/openobserve-dashboards.md). Each subdir under openobserve/dashboards becomes an
  # OpenObserve folder. The `title` filter skips non-dashboard JSON (e.g. the raw log samples under
  # logs/, which are top-level arrays) so they never reach the importer. Adding a dashboard needs no
  # edit here — drop a titled JSON under the right subdir.
  openobserve_dashboard_dir   = "${path.module}/openobserve/dashboards"
  openobserve_dashboard_files = fileset(local.openobserve_dashboard_dir, "**/*.json")
  openobserve_dashboards = [
    for f in local.openobserve_dashboard_files : {
      name    = f
      content = file("${local.openobserve_dashboard_dir}/${f}")
    } if try(jsondecode(file("${local.openobserve_dashboard_dir}/${f}")).title, null) != null
  ]

  # Static seed+import script spliced verbatim (file(), no templating — it uses plain bash ${var});
  # credentials are injected at call time via the runcmd env, not baked into the script.
  openobserve_provision_sh = file("${path.module}/cloud-init/openobserve/provision.sh")
}

# --- server (the observability hub) — created SECOND ------------------------

resource "local_file" "server_ci" {
  filename = "${local.render_dir}/server.yaml"
  content = templatefile("${path.module}/cloud-init/server.yaml.tftpl", merge(local.flags, {
    ssh_pubkey          = local.ssh_pubkey
    prometheus_yml      = local.prometheus_yml
    compose_conf        = local.compose_conf
    alert_rules         = local.alert_rules
    blackbox_yml        = local.blackbox_yml
    alertmanager_yml    = local.alertmanager_yml
    otel_config         = local.otel_config
    grafana_datasources = local.grafana_datasources
    grafana_dash_prov   = local.grafana_dash_prov
    grafana_dashboards  = local.grafana_dashboards
    ssh_exporter_conf   = local.ssh_exporter_conf
    # OpenObserve dashboards (dropped as files, imported post-boot by the provision script) +
    # the credentials/org the script needs to reach the local OpenObserve + OTel Collector.
    openobserve_org          = local.openobserve_org
    openobserve_password     = local.openobserve_password
    openobserve_dashboards   = local.openobserve_dashboards
    openobserve_provision_sh = local.openobserve_provision_sh
    # Heimdall auto-seed (cloud-init). enable_heimdall comes from local.flags; the
    # seed toggle + script body + flag list are passed explicitly so enabled_exporters
    # stays a pure service-flag list.
    enable_heimdall_seed = var.enable_heimdall_seed
    heimdall_cli_py      = file("${path.module}/scripts/heimdall_cli.py")
    heimdall_seed_flags  = join(",", local.enabled_exporters)
    # Cross-cluster self log-shipping — the shared syslog-ng client drop-in, gated on a non-empty
    # log_shipping_target so the default `just up` stays isolated. See specs/cross-cluster.md.
    log_shipping_target = var.log_shipping_target
    syslog_client_conf  = local.syslog_client_conf
    # Cross-cluster DNS — the shared systemd-resolved drop-in, gated on a non-empty dns_server so
    # the default `just up` keeps the image default resolver. See specs/cross-cluster.md.
    dns_server        = var.dns_server
    dns_resolved_conf = local.dns_resolved_conf
    # Docker operator TUIs (wharf/oxker/dive) on the observability hub (the docker VM).
    enable_docker_tools    = var.enable_docker_tools
    docker_tools_installer = local.docker_tools_installer
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

# Standalone copy of the rendered prometheus.yml. `just up-connected` discovers other clusters'
# VM IPs AFTER the server is already up, sets extra_scrape_targets, re-applies (which re-renders
# this file but does NOT recreate the VM — a cloud-init content change never recreates a
# multipass_instance), then scp's this file onto the running server and restarts the Prometheus
# container. That hot-push is what lets the monitoring hub pick up cross-cluster targets without
# a recreate (which would churn the server IP that consumers push OTLP to). See specs/cross-cluster.md.
resource "local_file" "prometheus_yml" {
  filename = "${local.render_dir}/prometheus.yml"
  content  = local.prometheus_yml
}

# --- Hot-push artifacts (see specs/cross-cluster.md; `just refresh-cross-cluster`) ---
# Discrete per-VM renders of the DNS resolver + syslog shipper drop-ins, so a hub IP change can be
# scp'd onto an already-running VM (content-only tofu apply, no recreate) instead of a reprovision.
resource "local_file" "server_resolved_conf" {
  count    = local.use_dns ? 1 : 0
  filename = "${local.render_dir}/server-resolved.conf"
  content  = local.dns_resolved_conf
}

resource "local_file" "k0s_resolved_conf" {
  count    = local.use_dns ? 1 : 0
  filename = "${local.render_dir}/k0s-resolved.conf"
  content  = local.dns_resolved_conf
}

resource "local_file" "server_ship_conf" {
  count    = local.ship_logs ? 1 : 0
  filename = "${local.render_dir}/server-ship.conf"
  content  = local.syslog_client_conf
}

# --- k0s log shipping: post-apply endpoint injection ------------------------
# The k0s VM boots before the server, so its otelcol agent ships to a 127.0.0.1 placeholder
# until now. Re-render the agent config with the server's real IP, then push it onto the k0s
# VM and restart the unit. This is the one step that must happen AFTER both VMs exist — cloud
# -init alone can't express it. local-exec runs only at apply, so hermetic `command = plan`
# tests never shell out to multipass.

# Gated on the same condition as the consumer below: without count, the rendered config
# (which embeds openobserve_password) would be written to render_dir on disk even when log
# shipping is disabled.
resource "local_file" "k0s_otel_config" {
  count = var.enable_openobserve && var.enable_k0s_log_shipping ? 1 : 0

  filename = "${local.render_dir}/k0s-collector-config.yaml"
  content = templatefile("${path.module}/cloud-init/otel/k0s-collector-config.yaml.tftpl", {
    server_ip            = multipass_instance.server.ipv4
    openobserve_org      = local.openobserve_org
    openobserve_password = local.openobserve_password
  })
}

resource "terraform_data" "k0s_log_shipper" {
  count = var.enable_openobserve && var.enable_k0s_log_shipping ? 1 : 0

  # Re-run whenever the server IP, the credential, or the rendered config changes.
  triggers_replace = [
    multipass_instance.server.ipv4,
    local.openobserve_password,
    local_file.k0s_otel_config[0].content,
  ]

  # Wait for the k0s VM's cloud-init to finish (the otelcol-contrib unit is installed there)
  # before pushing config + restarting; a slow k0s boot would otherwise fail the restart. The
  # `|| systemctl start` fallback covers the case where the unit isn't active yet. Uses SSH/SCP,
  # not `multipass exec`/`transfer` — those don't route to VMs in this environment (see CLAUDE.md).
  provisioner "local-exec" {
    command = <<-EOT
      ssh -n ${local.ssh_opts} ubuntu@${multipass_instance.k0s.ipv4} 'cloud-init status --wait || true'
      scp ${local.ssh_opts} ${local_file.k0s_otel_config[0].filename} ubuntu@${multipass_instance.k0s.ipv4}:/tmp/otelcol-config.yaml
      ssh -n ${local.ssh_opts} ubuntu@${multipass_instance.k0s.ipv4} 'sudo cp /tmp/otelcol-config.yaml /etc/otelcol/collector-config.yaml'
      ssh -n ${local.ssh_opts} ubuntu@${multipass_instance.k0s.ipv4} 'sudo systemctl restart otelcol-contrib || sudo systemctl start otelcol-contrib'
    EOT
  }
}
