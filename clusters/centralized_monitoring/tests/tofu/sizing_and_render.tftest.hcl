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
      "node_exporter", "process-exporter", "netdata", "cadvisor",
      "filestat_exporter", "kube-state-metrics",
    ] : strcontains(local_file.k0s_ci.content, marker)])
    error_message = "k0s cloud-init must install the default-on exporter bundle"
  }
  assert {
    condition     = strcontains(local_file.k0s_ci.content, "ssh-ed25519 AAAATESTKEY")
    error_message = "k0s cloud-init must inject the SSH public key"
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
