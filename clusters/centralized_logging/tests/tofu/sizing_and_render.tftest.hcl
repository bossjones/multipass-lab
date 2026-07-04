# Layer 0/1 hermetic test — runs with `tofu test -test-directory=tests/tofu`.
# mock_provider means no Multipass is touched; command = plan asserts on rendered values.

mock_provider "multipass" {}

variables {
  # Provide an inline key so the test never depends on a real ~/.ssh file.
  ssh_pubkey = "ssh-ed25519 AAAATESTKEY centralized-logging-tests"

  # Pin these so the suite stays hermetic to whatever a developer has locally
  # uncommented in terraform.tfvars — `tofu test` auto-loads that file just like
  # plan/apply does. Runs that want them on override in their own variables {}.
  enable_coroot  = false
  enable_ingress = false

  # Pin cross-cluster opt-in vars OFF so *_off_by_default runs are hermetic to auto-loaded
  # *.auto.tfvars (e.g. a leftover .cross-cluster.auto.tfvars.json). On-runs override. See specs/internal-ca.md.
  dns_server       = ""
  internal_ca_cert = ""
  ntp_server       = ""
}

run "sizing_image_names_and_central_render" {
  command = plan

  # --- sizing -------------------------------------------------------------
  assert {
    condition     = multipass_instance.central.cpus == 2
    error_message = "central cpus should be 2"
  }
  assert {
    condition     = multipass_instance.central.memory == "2G"
    error_message = "central memory should be 2G"
  }
  assert {
    condition     = multipass_instance.central.disk == "40G"
    error_message = "central disk should be 40G"
  }
  assert {
    condition     = multipass_instance.k0s.memory == "2G"
    error_message = "k0s memory should be 2G"
  }
  assert {
    condition     = multipass_instance.docker.memory == "4G"
    error_message = "docker memory should be 4G"
  }

  # --- image + names ------------------------------------------------------
  assert {
    condition     = multipass_instance.central.image == "24.04"
    error_message = "image should be 24.04"
  }
  assert {
    condition     = multipass_instance.central.name == "centralized-logging-central"
    error_message = "central name should carry the name_prefix"
  }
  assert {
    condition     = multipass_instance.k0s.name == "centralized-logging-k0s"
    error_message = "k0s name should carry the name_prefix"
  }
  assert {
    condition     = multipass_instance.docker.name == "centralized-logging-docker"
    error_message = "docker name should carry the name_prefix"
  }

  # --- central cloud-init carries the syslog-ng server config -------------
  assert {
    condition     = strcontains(local_file.central_ci.content, "/var/log/remote")
    error_message = "central cloud-init must contain the syslog-ng file sink path"
  }
  assert {
    condition     = strcontains(local_file.central_ci.content, "transport(\"tcp\")")
    error_message = "central cloud-init must contain the syslog-ng TCP network source"
  }
  assert {
    condition     = strcontains(local_file.central_ci.content, "ssh-ed25519 AAAATESTKEY")
    error_message = "central cloud-init must inject the SSH public key"
  }

  # default hostname_source = keep -> keep-hostname(yes)
  assert {
    condition     = strcontains(local_file.central_ci.content, "keep-hostname(yes)")
    error_message = "default hostname_source (keep) must render keep-hostname(yes)"
  }
}

run "hostname_source_dns_renders_use_dns" {
  command = plan

  variables {
    ssh_pubkey      = "ssh-ed25519 AAAATESTKEY centralized-logging-tests"
    hostname_source = "dns"
  }

  assert {
    condition     = strcontains(local_file.central_ci.content, "use-dns(yes)")
    error_message = "hostname_source = dns must render use-dns(yes)"
  }
}

# --- metrics / exporter layer (default flags = all on except journald) -------

run "exporters_render_with_defaults" {
  command = plan

  # central: node_exporter, syslog-ng textfile, systemd_exporter, process, filestat.
  assert {
    condition     = strcontains(local_file.central_ci.content, "node_exporter-1.8.2")
    error_message = "central must install node_exporter v1.8.2"
  }
  assert {
    condition     = strcontains(local_file.central_ci.content, "syslogng-textfile.sh")
    error_message = "central must render the syslog-ng textfile collector script"
  }
  assert {
    condition     = strcontains(local_file.central_ci.content, "syslog-ng-ctl stats prometheus")
    error_message = "central textfile script must dump native syslog-ng prometheus stats"
  }
  assert {
    condition     = strcontains(local_file.central_ci.content, "--web.listen-address=:9558")
    error_message = "central must install systemd_exporter on :9558"
  }
  assert {
    condition     = strcontains(local_file.central_ci.content, "--systemd.collector.unit-include=")
    error_message = "central systemd_exporter must be scoped with a curated unit-include"
  }
  assert {
    condition     = strcontains(local_file.central_ci.content, "process-exporter-0.8.7")
    error_message = "central must install process-exporter v0.8.7"
  }
  assert {
    condition     = strcontains(local_file.central_ci.content, "-threads=false -gather-smaps=false -remove-empty-groups")
    error_message = "central process-exporter must run with the low-cardinality perf flags"
  }
  assert {
    condition     = strcontains(local_file.central_ci.content, "/var/log/remote/*/*.log")
    error_message = "central filestat must watch /var/log/remote"
  }

  # k0s: cadvisor on :8089 (not :8080) + kubelet read-only port + kube-state-metrics.
  assert {
    condition     = strcontains(local_file.k0s_ci.content, "cadvisor --port=8089")
    error_message = "k0s cAdvisor must bind :8089 (not :8080)"
  }
  assert {
    condition     = strcontains(local_file.k0s_ci.content, "--read-only-port=10255")
    error_message = "k0s must enable the kubelet read-only port 10255"
  }
  assert {
    condition     = strcontains(local_file.k0s_ci.content, "kube-state-metrics")
    error_message = "k0s must render the kube-state-metrics deployment"
  }
  # Debug tooling (unconditional): ccze (apt), k9s + stern (release tarballs), and an admin
  # kubeconfig for the ubuntu login so k9s/stern connect out-of-box.
  assert {
    condition = alltrue([for marker in [
      "ccze", "derailed/k9s", "k9s_Linux_{ARCH}", "stern/stern", "stern_1.34.0",
      "/home/ubuntu/.kube/config",
    ] : strcontains(local_file.k0s_ci.content, marker)])
    error_message = "k0s cloud-init must install ccze/k9s/stern and drop the ubuntu kubeconfig"
  }

  # docker: cadvisor on :8089 + Traefik metrics entrypoint.
  assert {
    condition     = strcontains(local_file.docker_ci.content, "cadvisor --port=8089")
    error_message = "docker cAdvisor must bind :8089 (not :8080, the Traefik dashboard)"
  }
  assert {
    condition     = strcontains(local_file.docker_ci.content, "--entrypoints.metrics.address=:8082")
    error_message = "docker Traefik must expose a Prometheus metrics entrypoint on :8082"
  }

  # journald-exporter is off by default (x86-64-only upstream binary).
  assert {
    condition     = !strcontains(local_file.central_ci.content, "journald-exporter")
    error_message = "journald-exporter must be absent by default (enable_journald_exporter=false)"
  }

  # filestat is central-only.
  assert {
    condition     = !strcontains(local_file.k0s_ci.content, "filestat_exporter") && !strcontains(local_file.docker_ci.content, "filestat_exporter")
    error_message = "filestat_exporter must only render on central"
  }

  # netdata: installs on ALL three VMs by default, telemetry opted out.
  assert {
    condition = alltrue([for c in [
      local_file.central_ci.content, local_file.k0s_ci.content, local_file.docker_ci.content,
    ] : strcontains(c, "netdata-kickstart.sh")])
    error_message = "netdata kickstart install block must render on all three VMs by default"
  }
  assert {
    condition = alltrue([for c in [
      local_file.central_ci.content, local_file.k0s_ci.content, local_file.docker_ci.content,
    ] : strcontains(c, ".opt-out-from-anonymous-statistics")])
    error_message = "netdata install must drop the anonymous-statistics opt-out file on every VM"
  }
}

run "disabled_flags_omit_install_blocks" {
  command = plan

  variables {
    enable_filestat_exporter = false
    enable_cadvisor          = false
    enable_traefik_metrics   = false
  }

  assert {
    condition     = !strcontains(local_file.central_ci.content, "filestat_exporter")
    error_message = "disabled filestat must not render on central"
  }
  assert {
    condition     = !strcontains(local_file.k0s_ci.content, "cadvisor --port=8089")
    error_message = "disabled cadvisor must not render on k0s"
  }
  assert {
    condition     = !strcontains(local_file.docker_ci.content, "--entrypoints.metrics.address=:8082")
    error_message = "disabled traefik metrics must not render in the compose stack"
  }
}

run "netdata_off_omits_install_and_job" {
  command = plan

  variables {
    enable_netdata = false
  }

  # No install block on any VM and no scrape job in the docker VM's inline Prometheus.
  assert {
    condition = alltrue([for c in [
      local_file.central_ci.content, local_file.k0s_ci.content, local_file.docker_ci.content,
    ] : !strcontains(c, "netdata-kickstart.sh")])
    error_message = "disabling netdata must omit the kickstart install block from every VM"
  }
  assert {
    condition     = !strcontains(local_file.docker_ci.content, "job_name: logging-netdata")
    error_message = "disabling netdata must omit the logging-netdata scrape job"
  }
}

# --- time sync: every VM pins UTC + systemd-timesyncd (unconditional) --------

run "ntp_timezone_render" {
  command = plan

  # All three VMs must carry the UTC timezone + systemd-timesyncd NTP client.
  assert {
    condition = alltrue([for c in [
      local_file.central_ci.content, local_file.k0s_ci.content, local_file.docker_ci.content,
    ] : strcontains(c, "timezone: Etc/UTC")])
    error_message = "every VM cloud-init must pin timezone: Etc/UTC"
  }
  assert {
    condition = alltrue([for c in [
      local_file.central_ci.content, local_file.k0s_ci.content, local_file.docker_ci.content,
    ] : strcontains(c, "ntp_client: systemd-timesyncd")])
    error_message = "every VM cloud-init must set the NTP client to systemd-timesyncd"
  }

  # runcmd enforces UTC late (Multipass injects the host timezone during first boot and can
  # beat the declarative timezone key; runcmd runs after config modules, so it wins).
  assert {
    condition = alltrue([for c in [
      local_file.central_ci.content, local_file.k0s_ci.content, local_file.docker_ci.content,
    ] : strcontains(c, "timedatectl set-timezone Etc/UTC")])
    error_message = "every VM cloud-init runcmd must enforce timezone Etc/UTC"
  }

  # The injected timezone/ntp keys must keep the cloud-init valid YAML.
  assert {
    condition = alltrue([for c in [
      local_file.central_ci.content, local_file.k0s_ci.content, local_file.docker_ci.content,
    ] : can(yamldecode(c))])
    error_message = "rendered cloud-init must stay valid YAML after adding timezone/ntp"
  }
}

# --- Internal NTP source (var.ntp_server) --------------------------------------------
# Empty default => no timesyncd drop-in on any VM; non-empty => every VM points
# systemd-timesyncd at the injected NTP IP. Mirrors the dns_server gating pattern.

run "ntp_server_off_by_default" {
  command = plan
  assert {
    condition     = alltrue([for c in [local_file.central_ci.content, local_file.k0s_ci.content, local_file.docker_ci.content] : !strcontains(c, "99-centralized-ntp.conf")])
    error_message = "the internal NTP drop-in must be absent by default (ntp_server empty)"
  }
}

run "ntp_server_on_renders_dropin" {
  command = plan
  variables {
    ntp_server = "10.0.0.9"
  }
  assert {
    condition     = alltrue([for c in [local_file.central_ci.content, local_file.k0s_ci.content, local_file.docker_ci.content] : strcontains(c, "/etc/systemd/timesyncd.conf.d/99-centralized-ntp.conf")])
    error_message = "ntp_server set must render the timesyncd drop-in on every VM"
  }
  assert {
    condition     = alltrue([for c in [local_file.central_ci.content, local_file.k0s_ci.content, local_file.docker_ci.content] : strcontains(c, "NTP=10.0.0.9")])
    error_message = "the drop-in must point at the injected NTP IP"
  }
}

run "web_urls_core_and_flag_aware" {
  command = plan

  # core = the human dashboards on the docker VM (always composed).
  assert {
    condition     = length(output.web_urls.core) == 5
    error_message = "web_urls.core must list the 5 docker-VM dashboards (heimdall/grafana/prometheus/alertmanager/traefik)"
  }
  assert {
    condition     = length(output.web_urls.all) > length(output.web_urls.core)
    error_message = "web_urls.all must add the /metrics endpoints on top of core"
  }

  # journald-exporter is default-OFF, so its :12345 endpoint must be absent from all.
  assert {
    condition     = alltrue([for u in output.web_urls.all : !strcontains(u, ":12345/metrics")])
    error_message = "journald-exporter is default-off, so no :12345 URL may appear in web_urls.all"
  }
}

run "web_urls_journald_on_adds_endpoint" {
  command = plan

  variables {
    enable_journald_exporter = true
  }

  assert {
    condition     = anytrue([for u in output.web_urls.all : strcontains(u, ":12345/metrics")])
    error_message = "enabling journald-exporter must add its :12345 endpoint to web_urls.all"
  }
}

# --- docker VM Prometheus now self-monitors all 3 VMs; Grafana is provisioned ---------
# The docker VM's local Prometheus scrapes central/k0s (rendered IPs) + its own host
# exporters (__SELF_IP__, substituted at boot), and Grafana ships the dashboard set.

run "docker_prometheus_scrape_and_grafana_render" {
  command = plan

  # Default-on scrape jobs render, and the self-scrape placeholder is present for the
  # boot-time sed. central/k0s targets come from the injected runtime IPs.
  assert {
    condition = alltrue([for j in ["logging-node", "logging-systemd", "logging-process", "logging-cadvisor", "logging-filestat", "logging-kube-state", "logging-netdata"] :
    strcontains(local_file.docker_ci.content, "job_name: ${j}")])
    error_message = "docker Prometheus must render the default-on logging-* scrape jobs"
  }
  assert {
    condition     = strcontains(local_file.docker_ci.content, "__SELF_IP__:9100")
    error_message = "docker Prometheus must carry the __SELF_IP__ placeholder for host self-scrape"
  }
  assert {
    condition     = strcontains(local_file.docker_ci.content, "sed -i \"s/__SELF_IP__/$SELF_IP/g\"")
    error_message = "docker runcmd must substitute __SELF_IP__ into prometheus.yml before the stack starts"
  }

  # Grafana provisioning: datasource uid, folder-structure provider, and the dashboards.
  assert {
    condition     = strcontains(local_file.docker_ci.content, "uid: prometheus")
    error_message = "docker Grafana datasource must declare uid: prometheus"
  }
  assert {
    condition     = strcontains(local_file.docker_ci.content, "foldersFromFilesStructure: true")
    error_message = "docker Grafana dashboard provider must set foldersFromFilesStructure: true"
  }
  assert {
    condition = alltrue([for p in [
      "/opt/stack/grafana/dashboards/Instances/instance-overview.json",
      "/opt/stack/grafana/dashboards/Logging/logging-pipeline.json",
      "/opt/stack/grafana/dashboards/Netdata/netdata-fleet.json",
      "/opt/stack/grafana/dashboards/Netdata/netdata-instance.json",
      "/opt/stack/grafana/dashboards/Netdata/netdata-containers.json",
    ] : strcontains(local_file.docker_ci.content, p)])
    error_message = "docker Grafana must splice the provisioned dashboards (overview + logging pipeline + netdata)"
  }
  # Friendly `instance` labels so the Netdata dashboards' $instance picker reads a hostname.
  assert {
    condition = alltrue([for l in ["logging-central", "logging-docker", "logging-k0s"] :
    strcontains(local_file.docker_ci.content, l)])
    error_message = "logging-netdata scrape targets must carry friendly instance labels"
  }
  assert {
    condition     = strcontains(local_file.docker_ci.content, "encoding: gz+b64")
    error_message = "dashboard files must be written with gz+b64 encoding"
  }

  # The gz+b64 dashboard loop + expanded prometheus.yml must keep cloud-init valid YAML.
  assert {
    condition     = can(yamldecode(local_file.docker_ci.content))
    error_message = "docker cloud-init must stay valid YAML after adding scrape jobs + dashboards"
  }
}

# --- Coroot (opt-in eBPF observability on the k0s node) — default OFF -----------------

run "coroot_and_ingress_absent_by_default" {
  command = plan

  # No Coroot/ingress footprint on the default cluster.
  assert {
    condition     = !strcontains(local_file.k0s_ci.content, "coroot/coroot-ce")
    error_message = "coroot must not render when enable_coroot is false (default)"
  }
  assert {
    condition     = !strcontains(local_file.k0s_ci.content, "openebs-operator-lite")
    error_message = "the OpenEBS StorageClass must not render when enable_coroot is false"
  }
  assert {
    condition     = !strcontains(local_file.k0s_ci.content, "delete daemonset  openebs-ndm")
    error_message = "the OpenEBS NDM strip must not render when enable_coroot is false"
  }
  assert {
    condition     = !strcontains(local_file.k0s_ci.content, "ingress-nginx/controller")
    error_message = "ingress-nginx must not render when enable_ingress is false (default)"
  }

  # Default cluster keeps the small k0s VM (no auto-bump).
  assert {
    condition     = multipass_instance.k0s.memory == "2G" && multipass_instance.k0s.disk == "20G"
    error_message = "k0s must keep its small default sizing when enable_coroot is false"
  }

  # enabled_features output reflects both flags off.
  assert {
    condition     = output.enabled_features.coroot == false && output.enabled_features.ingress == false
    error_message = "enabled_features must report coroot=false, ingress=false by default"
  }

  # core dashboards stay at 5 (no Coroot tile).
  assert {
    condition     = length(output.web_urls.core) == 5
    error_message = "web_urls.core must stay 5 when Coroot is off"
  }
}

run "coroot_and_ingress_render_when_enabled" {
  command = plan

  variables {
    enable_coroot  = true
    enable_ingress = true
  }

  # Helm install of the operator + coroot-ce, with the pinned chart versions.
  assert {
    condition     = strcontains(local_file.k0s_ci.content, "coroot/coroot-operator") && strcontains(local_file.k0s_ci.content, "coroot/coroot-ce")
    error_message = "enable_coroot must render the operator + coroot-ce helm installs"
  }
  assert {
    condition     = strcontains(local_file.k0s_ci.content, "--version 0.9.7") && strcontains(local_file.k0s_ci.content, "--version 0.3.3")
    error_message = "enable_coroot must pin the operator (0.9.7) and coroot-ce (0.3.3) chart versions"
  }

  # Default StorageClass for the PVCs.
  assert {
    condition     = strcontains(local_file.k0s_ci.content, "openebs-operator-lite") && strcontains(local_file.k0s_ci.content, "is-default-class")
    error_message = "enable_coroot must install the OpenEBS default StorageClass"
  }

  # OpenEBS NDM (the ~4Gi besteffort leaker that caused global OOMs) must be stripped right after
  # the manifest applies, while the hostpath provisioner + openebs-device SC delete both render.
  # See specs/centralized-logging-k0s-perf.md.
  assert {
    condition     = strcontains(local_file.k0s_ci.content, "delete daemonset  openebs-ndm") && strcontains(local_file.k0s_ci.content, "delete storageclass openebs-device")
    error_message = "enable_coroot must strip OpenEBS NDM (daemonset + openebs-device SC) after installing the storage manifest"
  }

  # Memory-limit guardrails render on the Coroot server + node-agent + cluster-agent so a future
  # leak is OOM-killed in its own cgroup instead of causing a global OOM.
  assert {
    condition     = strcontains(local_file.k0s_ci.content, "limits:") && strcontains(local_file.k0s_ci.content, "nodeAgent:") && strcontains(local_file.k0s_ci.content, "clusterAgent:")
    error_message = "coroot values must set memory limits on the server + node-agent + cluster-agent"
  }

  # The rendered values file must override the chart's laptop-hostile defaults.
  assert {
    condition     = strcontains(local_file.k0s_ci.content, "shards: 1")
    error_message = "coroot values must set ClickHouse shards: 1 for the single-node lab"
  }
  assert {
    condition     = !strcontains(local_file.k0s_ci.content, "size: 100Gi")
    error_message = "coroot values must override the 100Gi ClickHouse storage default (would exceed the VM disk)"
  }
  assert {
    condition     = strcontains(local_file.k0s_ci.content, "size: 10Gi")
    error_message = "coroot ClickHouse storage must render the overridden 10Gi size"
  }

  # ingress-nginx installed + Coroot wired to it.
  assert {
    condition     = strcontains(local_file.k0s_ci.content, "ingress-nginx/controller-v1.15.1")
    error_message = "enable_ingress must install ingress-nginx (pinned controller-v1.15.1)"
  }
  assert {
    condition     = strcontains(local_file.k0s_ci.content, "className: nginx") && strcontains(local_file.k0s_ci.content, "host: coroot.local")
    error_message = "with ingress on, the Coroot values must reference the nginx ingress class + host"
  }

  # k0s VM auto-bumped for the Coroot stack.
  assert {
    condition     = multipass_instance.k0s.memory == "8G" && multipass_instance.k0s.disk == "50G" && multipass_instance.k0s.cpus == 4
    error_message = "enable_coroot must auto-bump the k0s VM to 4 vCPU / 8G / 50G"
  }

  # Outputs reflect the enabled feature + add the Coroot UI tile.
  assert {
    condition     = output.enabled_features.coroot == true && output.enabled_features.ingress == true
    error_message = "enabled_features must report coroot=true, ingress=true"
  }
  assert {
    condition     = length(output.web_urls.core) == 6 && anytrue([for u in output.web_urls.core : strcontains(u, ":30080")])
    error_message = "enabling Coroot must add its :30080 NodePort UI to web_urls.core"
  }

  # cloud-init must stay valid YAML with the Coroot/ingress write_files + values spliced in.
  assert {
    condition     = can(yamldecode(local_file.k0s_ci.content))
    error_message = "k0s cloud-init must stay valid YAML after adding the Coroot + ingress blocks"
  }
}

# --- Docker operator tooling (wharf/oxker/dive) — default ON on the docker VM only ----

run "docker_tools_render_by_default" {
  command = plan

  # The shared installer is spliced into the docker VM and invoked from runcmd.
  assert {
    condition     = strcontains(local_file.docker_ci.content, "install-docker-tools.sh")
    error_message = "docker VM must install the docker operator TUIs by default"
  }
  assert {
    condition = alltrue([for m in [
      "idesyatov/wharf", "mrjackwills/oxker", "wagoodman/dive",
      "WHARF_VERSION=\"0.9.1\"", "OXKER_VERSION=\"0.13.2\"", "DIVE_VERSION=\"0.13.1\"",
    ] : strcontains(local_file.docker_ci.content, m)])
    error_message = "docker cloud-init must reference the pinned wharf/oxker/dive releases"
  }
  # It's a docker-only tool — the non-docker VMs must never carry it.
  assert {
    condition     = !strcontains(local_file.central_ci.content, "install-docker-tools.sh") && !strcontains(local_file.k0s_ci.content, "install-docker-tools.sh")
    error_message = "install-docker-tools.sh must only render on the docker VM"
  }
  # cloud-init must stay valid YAML with the installer script spliced in.
  assert {
    condition     = can(yamldecode(local_file.docker_ci.content))
    error_message = "docker cloud-init must stay valid YAML after adding the docker-tools installer"
  }
}

run "docker_tools_absent_when_disabled" {
  command = plan

  variables {
    enable_docker_tools = false
  }

  assert {
    condition     = !strcontains(local_file.docker_ci.content, "install-docker-tools.sh")
    error_message = "disabled enable_docker_tools must omit the installer from the docker VM"
  }
}

run "ingress_without_coroot" {
  command = plan

  variables {
    enable_ingress = true
  }

  # ingress can be adopted on its own — controller renders, Coroot does not.
  assert {
    condition     = strcontains(local_file.k0s_ci.content, "ingress-nginx/controller-v1.15.1")
    error_message = "enable_ingress alone must still install ingress-nginx"
  }
  assert {
    condition     = !strcontains(local_file.k0s_ci.content, "coroot/coroot-ce")
    error_message = "enable_ingress must not drag in Coroot"
  }
  # k0s not bumped when only ingress is on (Coroot is what needs the RAM).
  assert {
    condition     = multipass_instance.k0s.memory == "2G"
    error_message = "ingress-only must not bump the k0s VM sizing"
  }
}

# --- Cross-cluster opt-in DNS (var.dns_server) ---------------------------------------
# Empty default => no systemd-resolved drop-in on any VM; non-empty => every VM points at
# the centralized_dns AdGuard Home resolver. Mirrors the log/otel gating pattern.

run "dns_off_by_default" {
  command = plan

  # No dns_server var set: the resolved.conf.d drop-in must be absent from every VM's cloud-init.
  assert {
    condition = alltrue([for c in [
      local_file.central_ci.content, local_file.k0s_ci.content, local_file.docker_ci.content,
    ] : !strcontains(c, "resolved.conf.d/99-centralized-dns.conf")])
    error_message = "dns_server unset must not render the centralized-dns resolved.conf drop-in on any VM"
  }
}

run "dns_on_renders_resolved_conf" {
  command = plan

  variables {
    dns_server = "10.7.7.7"
  }

  # Every VM must gain the drop-in file...
  assert {
    condition = alltrue([for c in [
      local_file.central_ci.content, local_file.k0s_ci.content, local_file.docker_ci.content,
    ] : strcontains(c, "99-centralized-dns.conf")])
    error_message = "dns_server set must render the 99-centralized-dns.conf drop-in on every VM"
  }
  # ...pointing systemd-resolved at the configured resolver IP.
  assert {
    condition = alltrue([for c in [
      local_file.central_ci.content, local_file.k0s_ci.content, local_file.docker_ci.content,
    ] : strcontains(c, "DNS=10.7.7.7")])
    error_message = "dns_server set must render DNS=<ip> into every VM's resolved.conf drop-in"
  }
  # The injected drop-in must keep the cloud-init valid YAML.
  assert {
    condition = alltrue([for c in [
      local_file.central_ci.content, local_file.k0s_ci.content, local_file.docker_ci.content,
    ] : can(yamldecode(c))])
    error_message = "rendered cloud-init must stay valid YAML after adding the DNS drop-in"
  }
}

# --- Fleet-wide internal-CA trust (var.internal_ca_cert) -----------------------------
# Empty default => no CA cert file / update-ca-certificates on any VM; non-empty => every VM
# drops the root CA into the OS trust store at first boot. Mirrors the dns_server gating pattern.
# `just up-connected` injects it from centralized_pki. See specs/internal-ca.md.

run "internal_ca_off_by_default" {
  command = plan

  # No internal_ca_cert var set: the trust-store cert file must be absent from every VM's cloud-init.
  assert {
    condition = alltrue([for c in [
      local_file.central_ci.content, local_file.k0s_ci.content, local_file.docker_ci.content,
    ] : !strcontains(c, "internal-root-ca.crt")])
    error_message = "internal_ca_cert unset must not render the internal-root-ca.crt trust-store file on any VM"
  }
}

run "internal_ca_on_renders_trust" {
  command = plan

  variables {
    internal_ca_cert = "-----BEGIN CERTIFICATE-----\nMIITESTROOTCA\n-----END CERTIFICATE-----"
  }

  # Every VM must gain the trust-store cert file...
  assert {
    condition = alltrue([for c in [
      local_file.central_ci.content, local_file.k0s_ci.content, local_file.docker_ci.content,
    ] : strcontains(c, "/usr/local/share/ca-certificates/internal-root-ca.crt")])
    error_message = "internal_ca_cert set must drop the root CA into /usr/local/share/ca-certificates on every VM"
  }
  # ...and run update-ca-certificates to install it into the OS trust store.
  assert {
    condition = alltrue([for c in [
      local_file.central_ci.content, local_file.k0s_ci.content, local_file.docker_ci.content,
    ] : strcontains(c, "update-ca-certificates")])
    error_message = "internal_ca_cert set must run update-ca-certificates on every VM"
  }
  # The PEM body must actually be spliced into the rendered cloud-init.
  assert {
    condition = anytrue([for c in [
      local_file.central_ci.content, local_file.k0s_ci.content, local_file.docker_ci.content,
    ] : strcontains(c, "MIITESTROOTCA")])
    error_message = "internal_ca_cert set must splice the CA PEM body into the rendered cloud-init"
  }
}

# --- reverse_proxy_routes contract (fleet-edge Traefik; see specs/dynamic-traefik.md) ----------

run "reverse_proxy_routes_absent_by_default" {
  command = plan

  assert {
    condition     = length(output.reverse_proxy_routes) == 0
    error_message = "no fleet-edge route when enable_coroot is off (nothing to front)"
  }
}

run "reverse_proxy_routes_render_when_coroot_enabled" {
  command = plan

  variables {
    enable_coroot = true
  }

  assert {
    condition     = length(output.reverse_proxy_routes) == 1
    error_message = "enable_coroot must publish exactly one fleet-edge route"
  }
  assert {
    condition     = output.reverse_proxy_routes[0].host == "coroot" && output.reverse_proxy_routes[0].k0s == true
    error_message = "the coroot route must use host=coroot and k0s=true"
  }
  assert {
    condition     = output.reverse_proxy_routes[0].port == var.coroot_nodeport
    error_message = "the coroot route must use the configured NodePort"
  }
}
