# Layer 0/1 hermetic test — runs with `tofu test -test-directory=tests/tofu` (i.e. `just check`).
# mock_provider means no Multipass is touched; command = plan asserts on the RENDERED values only.
#
# This suite is the integration backstop for the whole centralized_k0s cluster: it asserts on the
# rendered output of every agent's work (core sizing/counts, the k0sctl.yaml, per-node cloud-init,
# HAProxy config) AND on the Vector agent's config directly. It IS the `just check` gate.

mock_provider "multipass" {}

variables {
  # Inline key so the test never depends on a real ~/.ssh file.
  ssh_pubkey = "ssh-ed25519 AAAATESTKEY centralized-k0s-tests"

  # Pin EVERY cross-cluster opt-in OFF at the file level so the *_off_by_default runs stay hermetic
  # to auto-loaded *.auto.tfvars (a stale .cross-cluster.auto.tfvars.json would otherwise flip them).
  # File-level vars outrank auto-loaded tfvars; on-runs override at run level. See CLAUDE.md.
  dns_server           = ""
  internal_ca_cert     = ""
  ntp_server           = ""
  enable_cilium        = false
  log_shipping_target  = ""
  openobserve_endpoint = ""
  openobserve_org      = ""
  openobserve_password = ""
  openobserve_stream   = ""
}

# =============================================================================
# DEFAULT topology: 1 controller + 2 workers, NO HAProxy (etcd single-member).
# =============================================================================

run "default_1cp_2w_topology" {
  command = plan

  # --- counts -------------------------------------------------------------
  assert {
    condition     = length(multipass_instance.controller) == 1
    error_message = "default must render exactly 1 controller"
  }
  assert {
    condition     = length(multipass_instance.worker) == 2
    error_message = "default must render exactly 2 workers"
  }
  assert {
    condition     = length(multipass_instance.haproxy) == 0
    error_message = "default (single controller) must render NO HAProxy VM"
  }

  # --- sizing -------------------------------------------------------------
  assert {
    condition     = multipass_instance.controller[0].cpus == 3
    error_message = "controller must have 3 vCPU (etcd + control plane + --enable-worker headroom)"
  }
  assert {
    condition     = multipass_instance.controller[0].memory == "3G"
    error_message = "controller must have 3G RAM (etcd OOM headroom)"
  }
  assert {
    condition     = multipass_instance.worker[0].cpus == 2
    error_message = "worker must have 2 vCPU"
  }
  assert {
    condition     = multipass_instance.worker[1].cpus == 2
    error_message = "second worker must also have 2 vCPU"
  }

  # --- names --------------------------------------------------------------
  assert {
    condition     = multipass_instance.controller[0].name == "centralized-k0s-controller-1"
    error_message = "controller name must carry name_prefix + 1-based index"
  }
  assert {
    condition     = multipass_instance.worker[1].name == "centralized-k0s-worker-2"
    error_message = "worker names must be 1-based"
  }

  # --- outputs ------------------------------------------------------------
  assert {
    condition     = output.k0s_api_endpoint == "k0s-api.k0s.lab"
    error_message = "k0s_api_endpoint must be the stable k0s-api.<domain> hostname"
  }
  assert {
    condition     = output.enabled_features.ha == false
    error_message = "enabled_features.ha must be false in single-controller mode"
  }
  assert {
    condition     = output.cross_cluster_enabled == false
    error_message = "cross_cluster_enabled must be false when no shipping vars are set"
  }
  # haproxy must be absent from the hosts map in default mode.
  assert {
    condition     = !contains(keys(output.hosts), "haproxy")
    error_message = "hosts output must NOT contain haproxy in single-controller mode"
  }
}

# =============================================================================
# k0sctl.yaml render (asserts on the k0sctl agent's output).
# =============================================================================

run "k0sctl_render_default" {
  command = plan

  assert {
    condition     = can(yamldecode(local_file.k0sctl.content))
    error_message = "rendered k0sctl.yaml must be valid YAML"
  }
  assert {
    condition     = strcontains(local_file.k0sctl.content, "storage.type: etcd") || strcontains(local_file.k0sctl.content, "type: etcd")
    error_message = "k0sctl.yaml must set the datastore to etcd (single-member in default mode)"
  }
  assert {
    condition     = strcontains(local_file.k0sctl.content, "privateAddress")
    error_message = "k0sctl.yaml must pin per-host privateAddress (never rely on k0sctl fact-gathering)"
  }
  assert {
    condition     = strcontains(local_file.k0sctl.content, "--enable-worker")
    error_message = "controllers must carry --enable-worker via per-host installFlags"
  }
  assert {
    condition     = strcontains(local_file.k0sctl.content, "k0s-api.k0s.lab")
    error_message = "k0sctl.yaml must set externalAddress to the stable k0s-api.<domain> hostname"
  }
  assert {
    condition     = strcontains(local_file.k0sctl.content, "v1.34.9+k0s.0")
    error_message = "k0sctl.yaml must pin spec.k0s.version to k0s_version"
  }
}

# =============================================================================
# Per-node cloud-init render (asserts on the controller/worker agents' output).
# =============================================================================

run "node_cloud_init_default" {
  command = plan

  # OS-prep only — pinned tool installs + K0S_VERSION present on every node.
  assert {
    condition     = strcontains(local_file.controller_ci[0].content, "K0S_VERSION") && strcontains(local_file.worker_ci[0].content, "K0S_VERSION")
    error_message = "every node cloud-init must set K0S_VERSION for the pinned get.k0s.sh install"
  }
  assert {
    condition     = strcontains(local_file.controller_ci[0].content, "v1.34.9+k0s.0")
    error_message = "controller cloud-init must carry the pinned k0s version"
  }
  # UNCONDITIONAL DNS resolver warm-up gate (not only under dns_server != "") — the boot-race guard.
  assert {
    condition     = strcontains(local_file.controller_ci[0].content, "getent hosts") && strcontains(local_file.worker_ci[0].content, "getent hosts")
    error_message = "every node cloud-init must carry the unconditional resolver warm-up gate (getent hosts)"
  }
  # oh-my-zsh + per-tool zsh completions.
  assert {
    condition     = strcontains(local_file.controller_ci[0].content, "oh-my-zsh") && strcontains(local_file.worker_ci[0].content, "oh-my-zsh")
    error_message = "every node cloud-init must install oh-my-zsh"
  }
  # The Vector config must be embedded into each node's cloud-init.
  assert {
    condition     = strcontains(local_file.controller_ci[0].content, "sources.journald") && strcontains(local_file.worker_ci[0].content, "sources.journald")
    error_message = "every node cloud-init must embed the Vector config (journald source)"
  }
  assert {
    condition     = strcontains(local_file.controller_ci[0].content, "/var/log/pods") && strcontains(local_file.worker_ci[0].content, "/var/log/pods")
    error_message = "every node cloud-init must embed the Vector pod-log file source (/var/log/pods)"
  }
  # Vector is installed UNCONDITIONALLY (collection is always on; config falls back to a local
  # blackhole when unwired). A plain `just up` (all ship-vars empty here) must still create the
  # binary + vector.service, or `test_vector_service_running` fails live.
  assert {
    condition     = strcontains(local_file.controller_ci[0].content, "enable --now vector") && strcontains(local_file.worker_ci[0].content, "enable --now vector")
    error_message = "every node must install + enable Vector unconditionally, even when shipping is unwired"
  }
  # Valid YAML after all the spliced config.
  assert {
    condition     = can(yamldecode(local_file.controller_ci[0].content)) && can(yamldecode(local_file.worker_ci[0].content))
    error_message = "rendered node cloud-init must be valid YAML"
  }
}

# =============================================================================
# Vector config — asserted DIRECTLY on local.vector_config_{controller,worker}
# (the Vector agent's own deliverable, independent of the node-template agents).
# =============================================================================

run "vector_config_structure" {
  command = plan

  # Path 1: host + k0s-component logs via journald -> socket/syslog codec (NO Vector "syslog sink").
  assert {
    condition     = strcontains(local.vector_config_controller, "[sources.journald]")
    error_message = "Vector must have a journald source for host + k0s-component logs"
  }
  # Path 2: pod logs via file(/var/log/pods) + VRL path-parse — NEVER the kubernetes_logs source.
  assert {
    condition     = strcontains(local.vector_config_controller, "/var/log/pods/*/*/*.log")
    error_message = "Vector pod-log source must be a file source over /var/log/pods (present on all nodes)"
  }
  assert {
    condition     = strcontains(local.vector_config_controller, "type = \"file\"")
    error_message = "pod logs must use the Vector file source (no K8s API dependency)"
  }
  assert {
    condition     = !strcontains(local.vector_config_controller, "kubernetes_logs")
    error_message = "Vector must NOT use the kubernetes_logs source (locked decision — needs API at boot)"
  }
  # VRL path-parse extracting namespace / pod / container.
  assert {
    condition     = strcontains(local.vector_config_controller, "parse_regex") && strcontains(local.vector_config_controller, "namespace") && strcontains(local.vector_config_controller, "container")
    error_message = "Vector must VRL-parse the pod path into namespace/pod/container"
  }
  # Role tagging is threaded through (controller vs worker render differ).
  assert {
    condition     = strcontains(local.vector_config_controller, "controller") && strcontains(local.vector_config_worker, "worker")
    error_message = "Vector config must be role-tagged (controller vs worker)"
  }
  # Unwired (file-level defaults): a local blackhole sink consumes BOTH transforms so the config
  # ALWAYS validates (no dangling transforms) and vector.service stays active. Without this Vector
  # fails config validation (zero sinks) and crash-loops on a plain `just up`.
  assert {
    condition     = strcontains(local.vector_config_controller, "type = \"blackhole\"")
    error_message = "unwired Vector config must render a fallback blackhole sink so it always validates"
  }
  assert {
    condition     = strcontains(local.vector_config_controller, "inputs = [\"host_syslog_fields\", \"pod_meta\"]")
    error_message = "the fallback blackhole must consume BOTH transforms (no dangling transform)"
  }
  # No dollar-brace env token may survive into the rendered config — Vector interpolates it across
  # the whole file (comments included) and crash-loops on an unknown var (regression guard).
  assert {
    condition     = !strcontains(local.vector_config_controller, "$${")
    error_message = "rendered Vector config must contain no $${...} token (would crash Vector env-interpolation)"
  }
}

run "vector_shipping_sinks_on" {
  command = plan

  variables {
    log_shipping_target  = "10.9.9.9:514"
    openobserve_endpoint = "10.8.8.8:5080"
    openobserve_org      = "default"
    openobserve_stream   = "k0s_pods"
    openobserve_password = "s3cret"
  }

  # (1) journald -> socket sink, syslog codec, TCP -> logging:514.
  assert {
    condition     = strcontains(local.vector_config_controller, "[sinks.syslog_out]")
    error_message = "shipping on must render the host syslog socket sink"
  }
  assert {
    condition     = strcontains(local.vector_config_controller, "type = \"socket\"") && strcontains(local.vector_config_controller, "mode = \"tcp\"")
    error_message = "the syslog sink must be a TCP socket sink"
  }
  assert {
    condition     = strcontains(local.vector_config_controller, "codec = \"syslog\"")
    error_message = "the syslog sink must use the syslog encoding codec (RFC5424)"
  }
  assert {
    condition     = strcontains(local.vector_config_controller, "10.9.9.9:514")
    error_message = "the syslog sink must target log_shipping_target"
  }
  # (2a) OpenObserve http sink -> _json, basic auth, drop_newest.
  assert {
    condition     = strcontains(local.vector_config_controller, "[sinks.openobserve]") && strcontains(local.vector_config_controller, "type = \"http\"")
    error_message = "shipping on must render the OpenObserve http sink"
  }
  assert {
    condition     = strcontains(local.vector_config_controller, "/api/default/k0s_pods/_json")
    error_message = "OpenObserve sink uri must be /api/<org>/<stream>/_json"
  }
  assert {
    condition     = strcontains(local.vector_config_controller, "when_full = \"drop_newest\"")
    error_message = "OpenObserve sink must set buffer.when_full = drop_newest (a down hub must not back-pressure)"
  }
  assert {
    condition     = strcontains(local.vector_config_controller, "strategy = \"basic\"")
    error_message = "OpenObserve sink must use basic auth"
  }
  # (2b) a flat syslog archival copy of pod logs to centralized_logging.
  assert {
    condition     = strcontains(local.vector_config_controller, "[sinks.pod_syslog_archive]")
    error_message = "pod logs must also get a flat syslog archival copy to centralized_logging"
  }
  # The fallback blackhole is for the UNWIRED path only — real sinks take over when shipping is on.
  assert {
    condition     = !strcontains(local.vector_config_controller, "type = \"blackhole\"")
    error_message = "wired path must use the real sinks, not the blackhole fallback"
  }
}

# =============================================================================
# Post-apply bootstrap wiring (k0sctl + kubeconfig distribute + KSM, depends_on).
# =============================================================================

run "bootstrap_resources_exist" {
  command = plan

  # k0s_bootstrap re-runs on any node IP change or k0sctl content change.
  assert {
    condition     = length(terraform_data.k0s_bootstrap.triggers_replace) > 0
    error_message = "terraform_data.k0s_bootstrap must exist and trigger on node IPs + k0sctl content"
  }
  # kubeconfig_distribute + KSM both depend_on bootstrap (proved present by referencing them).
  assert {
    condition     = length(terraform_data.k0s_kubeconfig_distribute.triggers_replace) > 0
    error_message = "terraform_data.k0s_kubeconfig_distribute must exist (depends_on bootstrap)"
  }
  assert {
    condition     = length(terraform_data.k0s_ksm_manifest.triggers_replace) > 0
    error_message = "terraform_data.k0s_ksm_manifest must exist (depends_on bootstrap)"
  }
}

# =============================================================================
# HA opt-in: 3 controllers + 3 workers + HAProxy.
# =============================================================================

run "ha_3cp_3w_topology" {
  command = plan

  variables {
    k0s_control_plane_count = 3
    worker_count            = 3
  }

  assert {
    condition     = length(multipass_instance.controller) == 3
    error_message = "HA must render 3 controllers"
  }
  assert {
    condition     = length(multipass_instance.worker) == 3
    error_message = "HA must render 3 workers"
  }
  assert {
    condition     = length(multipass_instance.haproxy) == 1
    error_message = "HA (>1 controller) must render exactly 1 HAProxy VM"
  }
  assert {
    condition     = multipass_instance.controller[2].cpus == 3
    error_message = "HA controllers keep 3 vCPU"
  }
  assert {
    condition     = multipass_instance.haproxy[0].name == "centralized-k0s-haproxy"
    error_message = "HAProxy VM must carry the name_prefix"
  }
  # HAProxy is present in the hosts map + enabled_features in HA mode.
  assert {
    condition     = contains(keys(output.hosts), "haproxy")
    error_message = "hosts output must contain haproxy in HA mode"
  }
  assert {
    condition     = output.enabled_features.ha == true
    error_message = "enabled_features.ha must be true in HA mode"
  }
  # HAProxy cloud-init exposes the native :8405 Prometheus exporter frontend.
  assert {
    condition     = strcontains(local_file.haproxy_ci[0].content, "8405")
    error_message = "HAProxy cloud-init must bind the native Prometheus exporter on :8405"
  }
  assert {
    condition     = strcontains(local_file.haproxy_ci[0].content, "prometheus-exporter")
    error_message = "HAProxy cloud-init must use-service the prometheus-exporter"
  }
  # k0sctl still etcd (now 3-member quorum).
  assert {
    condition     = strcontains(local_file.k0sctl.content, "type: etcd") || strcontains(local_file.k0sctl.content, "storage.type: etcd")
    error_message = "k0sctl.yaml must remain etcd in HA mode (3-member quorum)"
  }
  # web_urls.all includes the HAProxy :8405/metrics endpoint in HA mode.
  assert {
    condition     = anytrue([for u in output.web_urls.all : strcontains(u, ":8405/metrics")])
    error_message = "web_urls.all must include HAProxy :8405/metrics in HA mode"
  }
}

# =============================================================================
# Off-by-default: opt-in features render nothing when their vars are empty.
# =============================================================================

run "cilium_off_by_default" {
  command = plan

  # enable_cilium is false at file level — no Cilium wiring in the node cloud-init or k0sctl.
  assert {
    condition     = !strcontains(local_file.controller_ci[0].content, "cilium")
    error_message = "enable_cilium=false must render no Cilium install on nodes"
  }
  assert {
    condition     = output.enabled_features.cilium == false
    error_message = "enabled_features.cilium must be false by default"
  }
}

run "log_shipping_off_by_default" {
  command = plan

  # log_shipping_target + openobserve_endpoint empty (file-level) -> Vector renders its collection
  # sources but NO shipping sinks (turnkey + isolated).
  assert {
    condition     = !strcontains(local.vector_config_controller, "[sinks.syslog_out]")
    error_message = "empty log_shipping_target must omit the host syslog sink"
  }
  assert {
    condition     = !strcontains(local.vector_config_controller, "[sinks.pod_syslog_archive]")
    error_message = "empty log_shipping_target must omit the pod syslog archival sink"
  }
  assert {
    condition     = !strcontains(local.vector_config_controller, "[sinks.openobserve]")
    error_message = "empty openobserve_endpoint must omit the OpenObserve http sink"
  }
  # But the collection sources are ALWAYS present (Vector still collects locally)...
  assert {
    condition     = strcontains(local.vector_config_controller, "[sources.journald]") && strcontains(local.vector_config_controller, "[sources.pod_logs]")
    error_message = "Vector must always render its journald + pod_logs sources even when shipping off"
  }
  # ...draining into a local blackhole so the config is valid (>=1 sink) and vector.service runs.
  assert {
    condition     = strcontains(local.vector_config_controller, "[sinks.local_blackhole]")
    error_message = "unwired Vector config must render the local_blackhole fallback sink"
  }
  assert {
    condition     = output.cross_cluster_enabled == false
    error_message = "cross_cluster_enabled must be false when both shipping vars are empty"
  }
}
