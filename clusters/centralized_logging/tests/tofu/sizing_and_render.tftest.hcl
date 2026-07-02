# Layer 0/1 hermetic test — runs with `tofu test -test-directory=tests/tofu`.
# mock_provider means no Multipass is touched; command = plan asserts on rendered values.

mock_provider "multipass" {}

variables {
  # Provide an inline key so the test never depends on a real ~/.ssh file.
  ssh_pubkey = "ssh-ed25519 AAAATESTKEY centralized-logging-tests"
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
    condition = alltrue([for j in ["logging-node", "logging-systemd", "logging-process", "logging-cadvisor", "logging-filestat", "logging-kube-state"] :
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
    ] : strcontains(local_file.docker_ci.content, p)])
    error_message = "docker Grafana must splice the provisioned dashboards (overview + logging pipeline)"
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
