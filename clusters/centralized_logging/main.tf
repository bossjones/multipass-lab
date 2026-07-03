locals {
  # Explicit inline key wins; otherwise read the pubkey file if it exists; otherwise empty.
  ssh_pubkey = var.ssh_pubkey != "" ? var.ssh_pubkey : (
    fileexists(pathexpand(var.ssh_pubkey_path)) ? trimspace(file(pathexpand(var.ssh_pubkey_path))) : ""
  )

  render_dir = "${path.module}/.rendered"

  # Interactive docker tooling installer (wharf/oxker/dive), shared byte-identically
  # across every cluster with a docker VM. Static script → file() (no templating);
  # embedded into the docker VM cloud-init via write_files and run under enable_docker_tools.
  docker_tools_installer = file("${path.module}/../_shared/cloud-init/install-docker-tools.sh")

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
    enable_netdata            = var.enable_netdata
  }

  # Sorted list of active flags — exported as enabled_exporters and consumed by
  # tests/testinfra/conftest.py so the live suite asserts only what is on.
  enabled_exporters = sort([for k, v in local.flags : k if v])

  # Coroot (opt-in, k0s only). Kept out of local.flags on purpose so enabled_exporters stays
  # the metrics-exporter set; enable_coroot/enable_ingress are threaded straight into the k0s
  # templatefile below and surfaced separately via the enabled_features output. See specs/coroot.md.

  # Coroot bundles Prometheus + ClickHouse, so the k0s VM must be much larger when it is on.
  # Auto-bump sizing on enable_coroot so the default (coroot-off) cluster stays small while an
  # `enable_coroot=true` apply gets enough headroom without a manual tfvars edit. cpus takes the
  # max of the configured value and the Coroot floor; memory/disk use the Coroot floor.
  k0s_size = var.enable_coroot ? {
    cpus   = max(var.k0s_client.cpus, 4)
    memory = "8G"
    disk   = "50G"
  } : var.k0s_client

  # coroot-ce Helm values (sizing/ingress/nodeport overrides), rendered unconditionally but only
  # written to the VM + used when enable_coroot. Overrides the chart's laptop-hostile defaults
  # (ClickHouse storage 100Gi, server memory request 4Gi). See cloud-init/coroot/.
  coroot_values = templatefile("${path.module}/cloud-init/coroot/coroot-values.yaml.tftpl", {
    enable_ingress             = var.enable_ingress
    coroot_host                = var.coroot_host
    coroot_nodeport            = var.coroot_nodeport
    coroot_server_memory       = var.coroot_server_memory
    coroot_server_memory_limit = var.coroot_server_memory_limit
    coroot_nodeagent_memory    = var.coroot_nodeagent_memory
    coroot_clusteragent_memory = var.coroot_clusteragent_memory
    coroot_prometheus_storage  = var.coroot_prometheus_storage
    coroot_clickhouse_storage  = var.coroot_clickhouse_storage
  })

  # Pre-computed `helm --version` flags (empty when the version var is "" = unpinned/latest), so
  # the in-VM install script stays free of nested template interpolation.
  coroot_operator_version_flag = var.coroot_operator_chart_version != "" ? "--version ${var.coroot_operator_chart_version}" : ""
  coroot_ce_version_flag       = var.coroot_ce_chart_version != "" ? "--version ${var.coroot_ce_chart_version}" : ""

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

  # Grafana provisioning for the docker VM's Grafana: a Prometheus datasource (uid:
  # prometheus) + a foldersFromFilesStructure dashboard provider, plus the drop-a-file
  # dashboard sweep (mirrors centralized_monitoring). See specs/dashboards.md.
  grafana_datasources   = file("${path.module}/cloud-init/grafana/provisioning/datasources/datasources.yaml")
  grafana_dash_prov     = file("${path.module}/cloud-init/grafana/provisioning/dashboards/dashboards.yaml")
  grafana_dashboard_dir = "${path.module}/cloud-init/grafana/dashboards"
  grafana_dashboards = [for f in fileset(local.grafana_dashboard_dir, "**/*.json") : {
    name    = f
    content = file("${local.grafana_dashboard_dir}/${f}")
  }]

  # syslog-ng client config — references the central VM's runtime IP, which forces
  # OpenTofu to create `central` (and learn its ipv4) before rendering/launching clients.
  client_conf = templatefile("${path.module}/cloud-init/syslog-ng/client.conf.tftpl", {
    central_ip  = multipass_instance.central.ipv4
    syslog_port = var.syslog_port
  })

  # Cross-cluster DNS (opt-in). Non-empty var.dns_server points every VM's systemd-resolved at
  # the centralized_dns AdGuard Home resolver via a rendered drop-in (shared snippet). Empty (the
  # default) leaves the image resolver untouched. See specs/cross-cluster.md.
  use_dns = var.dns_server != ""
  dns_resolved_conf = local.use_dns ? templatefile("${path.module}/../_shared/cloud-init/use-dns.conf.tftpl", {
    dns_ip = split(":", var.dns_server)[0]
  }) : ""
}

# --- Central logging VM (syslog-ng server) ----------------------------------

resource "local_file" "central_ci" {
  filename = "${local.render_dir}/central.yaml"
  content = templatefile("${path.module}/cloud-init/central.yaml.tftpl", merge(local.flags, {
    ssh_pubkey        = local.ssh_pubkey
    server_conf       = local.server_conf
    dns_server        = var.dns_server
    dns_resolved_conf = local.dns_resolved_conf
    internal_ca_cert  = var.internal_ca_cert
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
    ssh_pubkey        = local.ssh_pubkey
    client_conf       = local.client_conf
    dns_server        = var.dns_server
    dns_resolved_conf = local.dns_resolved_conf
    internal_ca_cert  = var.internal_ca_cert
    # Coroot (opt-in). enable_coroot/enable_ingress gate the %{ if } blocks; the rendered
    # coroot-ce values + pinned chart versions drive the in-VM Helm install. See specs/coroot.md.
    enable_coroot                = var.enable_coroot
    enable_ingress               = var.enable_ingress
    coroot_values                = local.coroot_values
    coroot_operator_version_flag = local.coroot_operator_version_flag
    coroot_ce_version_flag       = local.coroot_ce_version_flag
  }))
}

resource "multipass_instance" "k0s" {
  name           = local.k0s_name
  image          = var.image
  cpus           = local.k0s_size.cpus
  memory         = local.k0s_size.memory
  disk           = local.k0s_size.disk
  cloudinit_file = local_file.k0s_ci.filename
}

# --- Docker stack client ----------------------------------------------------

resource "local_file" "docker_ci" {
  filename = "${local.render_dir}/docker-client.yaml"
  content = templatefile("${path.module}/cloud-init/docker-client.yaml.tftpl", merge(local.flags, {
    ssh_pubkey        = local.ssh_pubkey
    client_conf       = local.client_conf
    compose_conf      = local.compose_conf
    dns_server        = var.dns_server
    dns_resolved_conf = local.dns_resolved_conf
    internal_ca_cert  = var.internal_ca_cert
    # Peer IPs for the local Prometheus scrape config. Referencing central/k0s here forces
    # both to be created (and their DHCP IPs known) before the docker VM renders — the same
    # runtime IP-injection edge the syslog-ng client_conf already creates for central.
    central_ip          = multipass_instance.central.ipv4
    k0s_ip              = multipass_instance.k0s.ipv4
    grafana_datasources = local.grafana_datasources
    grafana_dash_prov   = local.grafana_dash_prov
    grafana_dashboards  = local.grafana_dashboards
    # Docker operator TUIs (wharf/oxker/dive) — this is the only docker VM in the cluster.
    enable_docker_tools    = var.enable_docker_tools
    docker_tools_installer = local.docker_tools_installer
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

# --- Hot-push artifacts (see specs/cross-cluster.md; `just refresh-cross-cluster`) ---
# Discrete per-VM renders of the DNS resolver drop-in, so a centralized_dns IP change can be
# scp'd onto an already-running VM (content-only tofu apply, no recreate) instead of a reprovision.
resource "local_file" "central_resolved_conf" {
  count    = local.use_dns ? 1 : 0
  filename = "${local.render_dir}/central-resolved.conf"
  content  = local.dns_resolved_conf
}

resource "local_file" "k0s_resolved_conf" {
  count    = local.use_dns ? 1 : 0
  filename = "${local.render_dir}/k0s-resolved.conf"
  content  = local.dns_resolved_conf
}

resource "local_file" "docker_resolved_conf" {
  count    = local.use_dns ? 1 : 0
  filename = "${local.render_dir}/docker-resolved.conf"
  content  = local.dns_resolved_conf
}
