# Layer 0/1 hermetic test — runs with `tofu test -test-directory=tests/tofu`.
# mock_provider means no Multipass is touched; command = plan asserts on rendered values.
# A fixed mock ipv4 lets us assert the injected k0s client IP lands in prometheus.yml.

mock_provider "multipass" {
  mock_resource "multipass_instance" {
    defaults = {
      ipv4 = "10.99.99.99"
    }
  }
}

variables {
  # Provide an inline key so the test never depends on a real ~/.ssh file.
  ssh_pubkey = "ssh-ed25519 AAAATESTKEY centralized-monitoring-tests"
  # Pin the Phase 2 internal-CA TLS opt-in OFF so a leftover .cross-cluster.auto.tfvars.json (from
  # `just up-connected --INTERNAL_TLS`) can't flip it on and break these plain-HTTP assertions.
  use_internal_tls   = false
  ca_ip              = ""
  stepca_ca_password = ""
  ntp_server         = ""
}

run "defaults_sizing_names_and_render" {
  command = plan

  # --- sizing -------------------------------------------------------------
  assert {
    condition     = multipass_instance.server.cpus == 4
    error_message = "server cpus should be 4"
  }
  assert {
    condition     = multipass_instance.server.memory == "8G"
    error_message = "server memory should be 8G"
  }
  assert {
    condition     = multipass_instance.server.disk == "40G"
    error_message = "server disk should be 40G"
  }
  assert {
    condition     = multipass_instance.k0s.cpus == 2
    error_message = "k0s cpus should be 2"
  }
  assert {
    condition     = multipass_instance.k0s.memory == "4G"
    error_message = "k0s memory should be 4G"
  }
  assert {
    condition     = multipass_instance.k0s.disk == "30G"
    error_message = "k0s disk should be 30G"
  }

  # --- image + names ------------------------------------------------------
  assert {
    condition     = multipass_instance.server.image == "24.04"
    error_message = "image should be 24.04"
  }
  assert {
    condition     = multipass_instance.server.name == "centralized-monitoring-server"
    error_message = "server name should carry the name_prefix"
  }
  assert {
    condition     = multipass_instance.k0s.name == "centralized-monitoring-k0s"
    error_message = "k0s name should carry the name_prefix"
  }

  # --- injected k0s IP becomes a scrape target ----------------------------
  assert {
    condition     = strcontains(local_file.server_ci.content, "10.99.99.99:9100")
    error_message = "prometheus.yml must scrape the injected k0s client IP (node job)"
  }

  # --- default scrape jobs render -----------------------------------------
  assert {
    condition = alltrue([for j in ["node", "cadvisor", "process", "netdata", "kube-state-metrics", "kubelet", "blackbox", "selfmetrics"] :
    strcontains(local_file.server_ci.content, "job_name: ${j}")])
    error_message = "every default-on scrape job must render in prometheus.yml"
  }

  # --- default scrape interval renders ------------------------------------
  assert {
    condition     = strcontains(local_file.server_ci.content, "scrape_interval: 15s")
    error_message = "default scrape interval (15s) must render"
  }

  # --- metrics ingestion: Prometheus remote_write -> OpenObserve ----------
  assert {
    condition = alltrue([for marker in [
      "remote_write:",
      "http://openobserve:5080/api/default/prometheus/api/v1/write",
      "username: admin@example.com",
      "password: Complexpass#123",
    ] : strcontains(local_file.server_ci.content, marker)])
    error_message = "prometheus.yml must remote_write scraped metrics into OpenObserve (default-on)"
  }

  # --- log ingestion: OTel Collector ships host + container logs ----------
  # Auth header is the OpenObserve root basic-auth token (rendered from the password,
  # replacing the old wrong root@example.com:admin literal).
  assert {
    condition     = strcontains(local_file.server_ci.content, "Basic ${base64encode("admin@example.com:Complexpass#123")}")
    error_message = "collector config must carry the correct OpenObserve basic-auth token"
  }
  assert {
    condition = alltrue([for marker in [
      "/var/lib/docker/containers/*/*.log", # container logs receiver
      "/var/log/syslog",                    # host logs receiver
      "stream-name: container_logs",        # OpenObserve stream for docker logs
      "stream-name: host_logs",             # OpenObserve stream for host logs
    ] : strcontains(local_file.server_ci.content, marker)])
    error_message = "collector config must tail container + host logs and route them to named OpenObserve streams"
  }
  # The otel-collector container must mount the host log sources read-only.
  assert {
    condition = alltrue([for mount in [
      "/var/lib/docker/containers:/var/lib/docker/containers:ro",
      "/var/log:/var/log:ro",
    ] : strcontains(local_file.server_ci.content, mount)])
    error_message = "compose must mount docker container logs + /var/log into otel-collector"
  }
  # Splicing the expanded collector config must keep the cloud-init valid YAML.
  assert {
    condition     = can(yamldecode(local_file.server_ci.content))
    error_message = "rendered server cloud-init must stay valid YAML after collector changes"
  }

  # --- compose carries the default-on server services ---------------------
  assert {
    condition = alltrue([for img in [
      "prom/prometheus:latest", "prom/alertmanager:latest", "grafana/grafana:latest",
      "public.ecr.aws/zinclabs/openobserve", "otel/opentelemetry-collector-contrib",
      "prom/blackbox-exporter", "lscr.io/linuxserver/heimdall", "louislam/uptime-kuma",
      "traefik:v3.1", "prom/statsd-exporter", "treydock/ssh_exporter",
    ] : strcontains(local_file.server_ci.content, img)])
    error_message = "compose must contain every default-on server service image"
  }

  # --- server cloud-init injects the SSH key ------------------------------
  assert {
    condition     = strcontains(local_file.server_ci.content, "ssh-ed25519 AAAATESTKEY")
    error_message = "server cloud-init must inject the SSH public key"
  }

  # --- k0s cloud-init installs the default-on exporter bundle + SSH key ----
  assert {
    condition = alltrue([for marker in [
      "node_exporter", "process-exporter", "systemd_exporter", "netdata", "cadvisor",
      "filestat_exporter", "kube-state-metrics",
    ] : strcontains(local_file.k0s_ci.content, marker)])
    error_message = "k0s cloud-init must install the default-on exporter bundle"
  }
  # systemd_exporter (:9558) + its curated unit-include, tuned process-exporter, and the
  # matching `systemd` scrape job in the server's rendered prometheus.yml.
  assert {
    condition     = strcontains(local_file.k0s_ci.content, "--web.listen-address=:9558") && strcontains(local_file.k0s_ci.content, "--systemd.collector.unit-include=")
    error_message = "k0s must install systemd_exporter on :9558 with a curated unit-include"
  }
  assert {
    condition     = strcontains(local_file.k0s_ci.content, "process-exporter-0.8.7") && strcontains(local_file.k0s_ci.content, "-threads=false -gather-smaps=false -remove-empty-groups")
    error_message = "k0s must install process-exporter v0.8.7 with the low-cardinality perf flags"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "job_name: systemd")
    error_message = "server prometheus.yml must scrape the systemd job"
  }
  assert {
    condition     = strcontains(local_file.k0s_ci.content, "ssh-ed25519 AAAATESTKEY")
    error_message = "k0s cloud-init must inject the SSH public key"
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

  # --- netdata: installs on BOTH VMs, telemetry opted out, server scraped via host gateway ---
  assert {
    condition = alltrue([for c in [local_file.server_ci.content, local_file.k0s_ci.content] :
    strcontains(c, "netdata-kickstart.sh")])
    error_message = "netdata kickstart install block must render on both the server and k0s VMs by default"
  }
  assert {
    condition = alltrue([for c in [local_file.server_ci.content, local_file.k0s_ci.content] :
    strcontains(c, ".opt-out-from-anonymous-statistics")])
    error_message = "netdata install must drop the anonymous-statistics opt-out file on both VMs"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "host.docker.internal:19999")
    error_message = "netdata scrape job must reach the host-installed server agent via host.docker.internal"
  }
  # Friendly `instance` labels so the Netdata dashboards' $instance picker reads a hostname.
  assert {
    condition = alltrue([for l in ["monitoring-server", "monitoring-k0s"] :
    strcontains(local_file.server_ci.content, l)])
    error_message = "netdata scrape targets must carry friendly instance labels (monitoring-server / monitoring-k0s)"
  }

  # --- k0s log shipping: otelcol-contrib agent installs (endpoint injected post-apply) ---
  assert {
    condition = alltrue([for marker in [
      "otelcol-contrib",                    # agent binary + systemd unit
      "/etc/otelcol/collector-config.yaml", # config path the unit reads
      "/var/log/pods/*/*/*.log",            # kubernetes pod logs
    ] : strcontains(local_file.k0s_ci.content, marker)])
    error_message = "k0s cloud-init must install the otelcol-contrib log-shipping agent"
  }
  # The post-apply-pushed config carries the real server IP (mock 10.99.99.99) + OpenObserve auth
  # and the k0s_host / k0s_pods stream tags.
  assert {
    condition = alltrue([for marker in [
      "http://10.99.99.99:5080/api/default",
      "Basic ${base64encode("admin@example.com:Complexpass#123")}",
      "k0s_host",
      "k0s_pods",
      "file_storage", # persistent filelog offsets so restarts don't re-ship every file
    ] : strcontains(local_file.k0s_otel_config[0].content, marker)])
    error_message = "the pushed k0s agent config must target the server IP with OpenObserve auth"
  }

  # --- Nice-to-have jobs are NOT rendered by default ----------------------
  assert {
    condition = alltrue([for j in ["osquery", "ebpf", "texporter", "ffmpeg", "script"] :
    !strcontains(local_file.server_ci.content, "job_name: ${j}")])
    error_message = "Nice-to-have jobs must be absent with default flags"
  }

  # --- lab-hostile Reach exporters (nut/nftables) are OFF by default ------
  assert {
    condition = alltrue([for j in ["nut", "nftables"] :
    !strcontains(local_file.server_ci.content, "job_name: ${j}")])
    error_message = "nut/nftables jobs must be absent by default (lab-hostile, default off)"
  }
  assert {
    condition     = !strcontains(local_file.k0s_ci.content, "nut_exporter")
    error_message = "nut_exporter install block must be absent by default"
  }
  assert {
    condition     = !strcontains(local_file.server_ci.content, "timberio/vector")
    error_message = "Vector (Nice, default off) must be absent from compose"
  }
}

run "scrape_interval_override_renders" {
  command = plan

  variables {
    ssh_pubkey                 = "ssh-ed25519 AAAATESTKEY centralized-monitoring-tests"
    prometheus_scrape_interval = "30s"
  }

  assert {
    condition     = strcontains(local_file.server_ci.content, "scrape_interval: 30s")
    error_message = "overridden scrape interval (30s) must render"
  }
}

run "ebpf_toggle_on_renders_install_and_job" {
  command = plan

  variables {
    ssh_pubkey           = "ssh-ed25519 AAAATESTKEY centralized-monitoring-tests"
    enable_ebpf_exporter = true
  }

  assert {
    condition     = strcontains(local_file.k0s_ci.content, "ebpf_exporter")
    error_message = "enabling ebpf must render its install block"
  }
  assert {
    condition     = strcontains(local_file.k0s_ci.content, "linux-headers")
    error_message = "ebpf install block must pull kernel linux-headers"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "job_name: ebpf")
    error_message = "enabling ebpf must render its scrape job"
  }
}

run "systemd_exporter_off_omits_install_and_job" {
  command = plan

  variables {
    ssh_pubkey              = "ssh-ed25519 AAAATESTKEY centralized-monitoring-tests"
    enable_systemd_exporter = false
  }

  assert {
    condition     = !strcontains(local_file.k0s_ci.content, "--web.listen-address=:9558")
    error_message = "disabling systemd_exporter must omit its install block on k0s"
  }
  assert {
    condition     = !strcontains(local_file.server_ci.content, "job_name: systemd")
    error_message = "disabling systemd_exporter must omit its scrape job"
  }
}

run "nut_toggle_on_renders_install_and_job" {
  command = plan

  variables {
    ssh_pubkey          = "ssh-ed25519 AAAATESTKEY centralized-monitoring-tests"
    enable_nut_exporter = true
  }

  assert {
    condition     = strcontains(local_file.k0s_ci.content, "nut_exporter")
    error_message = "enabling nut (lab-hostile, default off) must render its install block"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "job_name: nut")
    error_message = "enabling nut must render its scrape job"
  }
}

run "netdata_off_omits_install_and_job" {
  command = plan

  variables {
    ssh_pubkey     = "ssh-ed25519 AAAATESTKEY centralized-monitoring-tests"
    enable_netdata = false
  }

  # No install block on either VM, no scrape job, no host-gateway mapping in compose.
  assert {
    condition = alltrue([for c in [local_file.server_ci.content, local_file.k0s_ci.content] :
    !strcontains(c, "netdata-kickstart.sh")])
    error_message = "disabling netdata must omit the kickstart install block from both VMs"
  }
  assert {
    condition     = !strcontains(local_file.server_ci.content, "job_name: netdata")
    error_message = "disabling netdata must omit the netdata scrape job"
  }
  assert {
    condition     = !strcontains(local_file.server_ci.content, "host.docker.internal:host-gateway")
    error_message = "disabling netdata must omit the prometheus host-gateway mapping"
  }
}

run "openobserve_off_omits_remote_write" {
  command = plan

  variables {
    enable_openobserve = false
  }

  # No OpenObserve -> Prometheus must not remote_write to it, and the OTLP exporter
  # endpoint must be gone from the collector config.
  assert {
    condition     = !strcontains(local_file.server_ci.content, "remote_write:")
    error_message = "disabling OpenObserve must omit the prometheus remote_write block"
  }
  assert {
    condition     = !strcontains(local_file.server_ci.content, "http://openobserve:5080")
    error_message = "disabling OpenObserve must omit every OpenObserve endpoint (remote_write + OTel exporters)"
  }
  # ...and the dashboard seed/import machinery (script + dropped JSON) must be gone too.
  assert {
    condition = !anytrue([for marker in [
      "/usr/local/sbin/openobserve-provision.sh",
      "/opt/stack/openobserve/dashboards/",
    ] : strcontains(local_file.server_ci.content, marker)])
    error_message = "disabling OpenObserve must omit the dashboard seed/import script + dropped dashboards"
  }
}

run "k0s_log_shipping_off_omits_agent" {
  command = plan

  variables {
    enable_k0s_log_shipping = false
  }

  assert {
    condition     = !strcontains(local_file.k0s_ci.content, "otelcol-contrib")
    error_message = "disabling k0s log shipping must omit the otelcol agent from k0s cloud-init"
  }
}

run "heimdall_seed_renders_by_default" {
  command = plan

  # Heimdall + auto-seed are both default-on, so the server cloud-init must embed
  # the seed tool and the runtime seed steps (uv install, IP discovery, seed call).
  assert {
    condition = alltrue([for marker in [
      "/opt/stack/heimdall/heimdall_cli.py",
      "astral.sh/uv/install.sh",
      "ip -4 route get",
      "heimdall_cli.py seed",
    ] : strcontains(local_file.server_ci.content, marker)])
    error_message = "default render must embed the Heimdall seed tool + runcmd steps"
  }

  # The embedded script + block-scalar runcmd must keep the cloud-init valid YAML.
  assert {
    condition     = can(yamldecode(local_file.server_ci.content))
    error_message = "rendered server cloud-init must be valid YAML"
  }
}

run "heimdall_seed_off_omits_block" {
  command = plan

  variables {
    enable_heimdall_seed = false
  }

  # With seeding disabled the script and runcmd steps must be gone, even though
  # Heimdall itself stays in the compose stack.
  assert {
    condition = alltrue([for marker in [
      "/opt/stack/heimdall/heimdall_cli.py",
      "heimdall_cli.py seed",
    ] : !strcontains(local_file.server_ci.content, marker)])
    error_message = "enable_heimdall_seed=false must omit the seed write_file + runcmd"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "lscr.io/linuxserver/heimdall")
    error_message = "Heimdall service itself must remain when only seeding is off"
  }
}

run "heimdall_off_omits_seed" {
  command = plan

  variables {
    enable_heimdall = false
  }

  # No Heimdall -> no seed, regardless of the seed flag default.
  assert {
    condition     = !strcontains(local_file.server_ci.content, "heimdall_cli.py seed")
    error_message = "disabling Heimdall must also omit its seed step"
  }
}

# --- time sync: every VM pins UTC + systemd-timesyncd (unconditional) --------

run "ntp_timezone_render" {
  command = plan

  # Both VMs must carry the UTC timezone + systemd-timesyncd NTP client.
  assert {
    condition = alltrue([for c in [
      local_file.server_ci.content, local_file.k0s_ci.content,
    ] : strcontains(c, "timezone: Etc/UTC")])
    error_message = "every VM cloud-init must pin timezone: Etc/UTC"
  }
  assert {
    condition = alltrue([for c in [
      local_file.server_ci.content, local_file.k0s_ci.content,
    ] : strcontains(c, "ntp_client: systemd-timesyncd")])
    error_message = "every VM cloud-init must set the NTP client to systemd-timesyncd"
  }

  # runcmd enforces UTC late (Multipass injects the host timezone during first boot and can
  # beat the declarative timezone key; runcmd runs after config modules, so it wins).
  assert {
    condition = alltrue([for c in [
      local_file.server_ci.content, local_file.k0s_ci.content,
    ] : strcontains(c, "timedatectl set-timezone Etc/UTC")])
    error_message = "every VM cloud-init runcmd must enforce timezone Etc/UTC"
  }

  # The injected timezone/ntp keys must keep the cloud-init valid YAML.
  assert {
    condition = alltrue([for c in [
      local_file.server_ci.content, local_file.k0s_ci.content,
    ] : can(yamldecode(c))])
    error_message = "rendered cloud-init must stay valid YAML after adding timezone/ntp"
  }
}

run "ntp_server_off_by_default" {
  command = plan
  assert {
    condition     = alltrue([for c in [local_file.server_ci.content, local_file.k0s_ci.content] : !strcontains(c, "99-centralized-ntp.conf")])
    error_message = "the internal NTP drop-in must be absent by default (ntp_server empty)"
  }
}

run "ntp_server_on_renders_dropin" {
  command = plan
  variables {
    ntp_server = "10.0.0.9"
  }
  assert {
    condition     = alltrue([for c in [local_file.server_ci.content, local_file.k0s_ci.content] : strcontains(c, "/etc/systemd/timesyncd.conf.d/99-centralized-ntp.conf")])
    error_message = "ntp_server set must render the timesyncd drop-in on every VM"
  }
  assert {
    condition     = alltrue([for c in [local_file.server_ci.content, local_file.k0s_ci.content] : strcontains(c, "NTP=10.0.0.9")])
    error_message = "the drop-in must point at the injected NTP IP"
  }
}

run "web_urls_core_and_flag_aware" {
  command = plan

  # core = the human dashboards on the server VM; the mock fixes ipv4 = 10.99.99.99.
  assert {
    condition     = contains(output.web_urls.core, "http://10.99.99.99:3000")
    error_message = "web_urls.core must include the Grafana dashboard URL"
  }
  assert {
    condition     = contains(output.web_urls.core, "http://10.99.99.99:5080")
    error_message = "web_urls.core must include OpenObserve (default-on)"
  }
  assert {
    condition     = length(output.web_urls.all) > length(output.web_urls.core)
    error_message = "web_urls.all must add the /metrics endpoints on top of core"
  }
}

run "web_urls_disable_drops_endpoints" {
  command = plan

  variables {
    enable_openobserve   = false
    enable_node_exporter = false
  }

  # Disabled OpenObserve drops from core; disabled node_exporter drops every :9100 from all.
  assert {
    condition     = !contains(output.web_urls.core, "http://10.99.99.99:5080")
    error_message = "disabling OpenObserve must drop its URL from web_urls.core"
  }
  assert {
    condition     = alltrue([for u in output.web_urls.all : !strcontains(u, ":9100/metrics")])
    error_message = "disabling node_exporter must drop all :9100/metrics URLs from web_urls.all"
  }
}

# --- Grafana dashboards: drop-a-file provisioning + fixed datasource uid ------
# The fileset sweep must splice every dashboard JSON (custom + community imports)
# into the server cloud-init under its folder subdir, and the Prometheus datasource
# must declare uid: prometheus so every dashboard binds deterministically.

run "grafana_dashboards_render" {
  command = plan

  # Custom flagship + a community import land under their folder subdirectories.
  assert {
    condition = alltrue([for p in [
      "/opt/stack/grafana/dashboards/Instances/instance-overview.json",
      "/opt/stack/grafana/dashboards/Instances/processes-systemd.json",
      "/opt/stack/grafana/dashboards/Infrastructure/node-exporter-full.json",
      "/opt/stack/grafana/dashboards/Platform/alertmanager.json",
      "/opt/stack/grafana/dashboards/Kubernetes/kubernetes.json",
      "/opt/stack/grafana/dashboards/Netdata/netdata-fleet.json",
      "/opt/stack/grafana/dashboards/Netdata/netdata-instance.json",
      "/opt/stack/grafana/dashboards/Netdata/netdata-containers.json",
      "/opt/stack/grafana/dashboards/DNS/adguard-home.json",
      "/opt/stack/grafana/dashboards/DNS/unbound.json",
    ] : strcontains(local_file.server_ci.content, p)])
    error_message = "every dashboard JSON must be spliced into the server cloud-init under its folder subdir"
  }

  # Dashboards are embedded gzip+base64 (compact + keeps cloud-init valid YAML).
  assert {
    condition     = strcontains(local_file.server_ci.content, "encoding: gz+b64")
    error_message = "dashboard files must be written with gz+b64 encoding"
  }

  # The provisioned Prometheus datasource pins uid: prometheus (dashboards bind to it).
  assert {
    condition     = strcontains(local_file.server_ci.content, "uid: prometheus")
    error_message = "Grafana datasource must declare uid: prometheus"
  }

  # The file provider derives folders from the directory structure.
  assert {
    condition     = strcontains(local_file.server_ci.content, "foldersFromFilesStructure: true")
    error_message = "dashboard provider must set foldersFromFilesStructure: true"
  }
}

run "openobserve_dashboards_render" {
  command = plan

  # OpenObserve dashboards (default-on) are spliced under their folder subdirs and the seed+import
  # script + its runcmd invocation are present.
  assert {
    condition = alltrue([for marker in [
      "/opt/stack/openobserve/dashboards/Infrastructure/traces-overview.json",
      "/opt/stack/openobserve/dashboards/LogAnalysis/log-overview.json",
      "/opt/stack/openobserve/dashboards/Correlation/cause-effect.json",
      "/opt/stack/openobserve/dashboards/DNS/adguard-home.json",
      "/opt/stack/openobserve/dashboards/DNS/unbound.json",
      "/usr/local/sbin/openobserve-provision.sh",
      "openobserve-provision.sh || true",
    ] : strcontains(local_file.server_ci.content, marker)])
    error_message = "default render must embed the OpenObserve dashboards + seed/import script + runcmd"
  }

  # The `title` filter must keep the non-dashboard log-sample JSON (top-level arrays under logs/)
  # out of the cloud-init entirely — they'd crash the importer.
  assert {
    condition     = !strcontains(local_file.server_ci.content, "/opt/stack/openobserve/dashboards/logs/")
    error_message = "non-dashboard JSON (logs/*.json arrays) must be filtered out, not spliced in"
  }

  # The embedded script + gz+b64 dashboards must keep the cloud-init valid YAML.
  assert {
    condition     = can(yamldecode(local_file.server_ci.content))
    error_message = "rendered server cloud-init must be valid YAML"
  }
}

# --- Docker operator tooling (wharf/oxker/dive) — default ON on the server VM ---------

run "docker_tools_render_by_default" {
  command = plan

  assert {
    condition     = strcontains(local_file.server_ci.content, "install-docker-tools.sh")
    error_message = "server VM must install the docker operator TUIs by default"
  }
  assert {
    condition = alltrue([for m in [
      "idesyatov/wharf", "mrjackwills/oxker", "wagoodman/dive",
      "WHARF_VERSION=\"0.9.1\"", "OXKER_VERSION=\"0.13.2\"", "DIVE_VERSION=\"0.13.1\"",
    ] : strcontains(local_file.server_ci.content, m)])
    error_message = "server cloud-init must reference the pinned wharf/oxker/dive releases"
  }
  assert {
    condition     = output.docker_tools_enabled == true
    error_message = "docker_tools_enabled output must report true by default"
  }
  assert {
    condition     = can(yamldecode(local_file.server_ci.content))
    error_message = "server cloud-init must stay valid YAML after adding the docker-tools installer"
  }
}

run "docker_tools_absent_when_disabled" {
  command = plan

  variables {
    enable_docker_tools = false
  }

  assert {
    condition     = !strcontains(local_file.server_ci.content, "install-docker-tools.sh")
    error_message = "disabled enable_docker_tools must omit the installer from the server VM"
  }
}
