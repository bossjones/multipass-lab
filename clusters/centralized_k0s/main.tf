locals {
  # Explicit inline key wins; otherwise read the pubkey file if it exists; otherwise empty.
  ssh_pubkey = var.ssh_pubkey != "" ? var.ssh_pubkey : (
    fileexists(pathexpand(var.ssh_pubkey_path)) ? trimspace(file(pathexpand(var.ssh_pubkey_path))) : ""
  )

  render_dir = "${path.module}/.rendered"

  # k0sctl SSHes to the hosts itself, and the post-apply provisioners touch VMs over SSH
  # (multipass exec/transfer don't route to VMs in this environment — see CLAUDE.md). Both use
  # the private key matching the injected pubkey (path minus the trailing .pub).
  ssh_private_key = trimsuffix(pathexpand(var.ssh_pubkey_path), ".pub")
  ssh_opts        = "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8 -i ${local.ssh_private_key}"

  # >1 controller => HA opt-in: 3-member etcd quorum behind a conditional HAProxy edge.
  ha_mode = var.k0s_control_plane_count > 1

  # Stable API endpoint (backup/restore footgun fix): spec.api.externalAddress points at this
  # HOSTNAME, not the churning DHCP IP, so `k0s backup`/`restore` survives a rebuild. Resolves
  # to the HAProxy IP in HA mode / controller-1 in single mode (see dns_records / k0s_api_ipv4).
  k0s_api_host = "k0s-api.${var.domain}"

  # IPv4 the k0s API endpoint resolves to: the HAProxy VM in HA mode, controller-1 in single mode.
  # Threaded into the WORKER render only (k0s_api_ip) so each worker writes an /etc/hosts fallback
  # for k0s-api.<domain> at first boot — the join token connects offline, no DNS hub required.
  # NOT passed to the controller render: controller[0].ipv4 there would self-reference the
  # controller instance (dependency cycle); controllers handle their own /etc/hosts at runtime.
  k0s_api_ipv4 = local.ha_mode ? multipass_instance.haproxy[0].ipv4 : multipass_instance.controller[0].ipv4

  # Cross-cluster opt-in gates (empty defaults => plain `just up` stays turnkey + isolated).
  use_dns = var.dns_server != ""
  use_ntp = var.ntp_server != ""

  dns_resolved_conf = local.use_dns ? templatefile("${path.module}/../_shared/cloud-init/use-dns.conf.tftpl", {
    dns_ip = split(":", var.dns_server)[0]
  }) : ""

  # Baseline UTC time sync (unconditional) + opt-in internal NTP source drop-in (mirrors dns_server).
  ntp_timesync = templatefile("${path.module}/../_shared/cloud-init/ntp-timesync.yaml.tftpl", {})
  ntp_conf = local.use_ntp ? templatefile("${path.module}/../_shared/cloud-init/use-ntp.conf.tftpl", {
    ntp_ip = split(":", var.ntp_server)[0]
  }) : ""

  # Flags threaded into every node's cloud-init templatefile so each renders its own
  # %{ if enable_x ~}…%{ endif ~} install blocks.
  flags = {
    enable_cilium       = var.enable_cilium
    enable_netdata      = var.enable_netdata
    enable_netdata_ebpf = var.enable_netdata_ebpf
  }

  # Cross-cluster log-shipping var contract consumed by cloud-init/vector/vector.toml.tftpl
  # (owned by the vector agent). One Vector agent per node: journald -> syslog to
  # centralized_logging; /var/log/pods -> VRL path-parse -> OpenObserve http sink (+ syslog copy).
  # See spec § "Var plumbing". All-empty defaults => Vector ships nowhere (turnkey).
  vector_vars = {
    log_shipping_target  = var.log_shipping_target
    openobserve_endpoint = var.openobserve_endpoint
    openobserve_org      = var.openobserve_org
    openobserve_password = var.openobserve_password
    openobserve_stream   = var.openobserve_stream
  }

  # Vector config rendered per role (same template, role-tagged HOSTNAME/APP-NAME).
  vector_config_controller = templatefile("${path.module}/cloud-init/vector/vector.toml.tftpl", merge(local.vector_vars, {
    role = "controller"
  }))
  vector_config_worker = templatefile("${path.module}/cloud-init/vector/vector.toml.tftpl", merge(local.vector_vars, {
    role = "worker"
  }))

  # Common var map merged into every node cloud-init render (OS prep only — no k0s install,
  # no API-dependent step; k0sctl forms the cluster post-apply).
  node_common = merge(local.flags, {
    ssh_pubkey           = local.ssh_pubkey
    k0s_version          = var.k0s_version
    k0s_api_host         = local.k0s_api_host
    ntp_timesync         = local.ntp_timesync
    ntp_server           = var.ntp_server
    ntp_conf             = local.ntp_conf
    dns_server           = var.dns_server
    dns_resolved_conf    = local.dns_resolved_conf
    internal_ca_cert     = var.internal_ca_cert
    log_shipping_target  = var.log_shipping_target
    openobserve_endpoint = var.openobserve_endpoint
  })
}

# --- Controllers (count-driven) ---------------------------------------------
# `count` instances create in parallel — there is no "anchor" node. The real create-before-render
# edge is that local_file.k0sctl (and haproxy_ci) reference controller[*].ipv4 / worker[*].ipv4,
# forcing every VM created before the render + the post-apply k0sctl bootstrap.

resource "local_file" "controller_ci" {
  count    = var.k0s_control_plane_count
  filename = "${local.render_dir}/controller-${count.index + 1}.yaml"
  content = templatefile("${path.module}/cloud-init/controller.yaml.tftpl", merge(local.node_common, {
    role_index    = count.index + 1
    vector_config = local.vector_config_controller
    netdata_installer = var.enable_netdata ? templatefile("${path.module}/../_shared/cloud-init/install-netdata.sh.tftpl", {
      host_labels = { cluster = var.name_prefix, role = "controller-${count.index + 1}", environment = "lab" }
      enable_ebpf = var.enable_netdata_ebpf
    }) : ""
  }))
}

resource "multipass_instance" "controller" {
  count          = var.k0s_control_plane_count
  name           = "${var.name_prefix}-controller-${count.index + 1}"
  image          = var.image
  cpus           = var.controller_size.cpus
  memory         = var.controller_size.memory
  disk           = var.controller_size.disk
  cloudinit_file = local_file.controller_ci[count.index].filename
}

# --- Workers (count-driven) -------------------------------------------------

resource "local_file" "worker_ci" {
  count    = var.worker_count
  filename = "${local.render_dir}/worker-${count.index + 1}.yaml"
  content = templatefile("${path.module}/cloud-init/worker.yaml.tftpl", merge(local.node_common, {
    role_index    = count.index + 1
    k0s_api_ip    = local.k0s_api_ipv4
    vector_config = local.vector_config_worker
    netdata_installer = var.enable_netdata ? templatefile("${path.module}/../_shared/cloud-init/install-netdata.sh.tftpl", {
      host_labels = { cluster = var.name_prefix, role = "worker-${count.index + 1}", environment = "lab" }
      enable_ebpf = var.enable_netdata_ebpf
    }) : ""
  }))
}

resource "multipass_instance" "worker" {
  count          = var.worker_count
  name           = "${var.name_prefix}-worker-${count.index + 1}"
  image          = var.image
  cpus           = var.worker_size.cpus
  memory         = var.worker_size.memory
  disk           = var.worker_size.disk
  cloudinit_file = local_file.worker_ci[count.index].filename
}

# --- HAProxy edge (conditional on >1 controller) ----------------------------
# L4 passthrough for 6443 (apiserver) / 8132 (konnectivity) / 9443 (controller join) + a native
# Prometheus exporter on :8405. Its render references controller[*].ipv4, so it (and its VM) come
# up after the controllers. Single-controller mode creates no HAProxy — externalAddress -> controller-1.

resource "local_file" "haproxy_ci" {
  count    = local.ha_mode ? 1 : 0
  filename = "${local.render_dir}/haproxy.yaml"
  content = templatefile("${path.module}/cloud-init/haproxy.yaml.tftpl", {
    ssh_pubkey        = local.ssh_pubkey
    controller_ips    = multipass_instance.controller[*].ipv4
    ntp_timesync      = local.ntp_timesync
    ntp_server        = var.ntp_server
    ntp_conf          = local.ntp_conf
    dns_server        = var.dns_server
    dns_resolved_conf = local.dns_resolved_conf
    internal_ca_cert  = var.internal_ca_cert
    enable_netdata    = var.enable_netdata
    netdata_installer = var.enable_netdata ? templatefile("${path.module}/../_shared/cloud-init/install-netdata.sh.tftpl", {
      host_labels = { cluster = var.name_prefix, role = "haproxy", environment = "lab" }
      enable_ebpf = var.enable_netdata_ebpf
    }) : ""
  })
}

resource "multipass_instance" "haproxy" {
  count          = local.ha_mode ? 1 : 0
  name           = "${var.name_prefix}-haproxy"
  image          = var.image
  cpus           = var.haproxy_size.cpus
  memory         = var.haproxy_size.memory
  disk           = var.haproxy_size.disk
  cloudinit_file = local_file.haproxy_ci[0].filename
}

# --- k0sctl cluster config (ONE shared config; per-host installFlags/privateAddress) ---------
# Referencing controller[*].ipv4 AND worker[*].ipv4 forces every VM created before this render and
# before the bootstrap. privateAddress is pinned to the tofu-discovered ipv4 for every host (do NOT
# rely on k0sctl fact-gathering — it can pick a CNI bridge 10.244.x -> SAN/etcd-peer mismatch).
# externalAddress = k0s-api.<domain> in both modes. Controllers get --enable-worker via installFlags.

resource "local_file" "k0sctl" {
  filename = "${local.render_dir}/k0sctl.yaml"
  content = templatefile("${path.module}/cloud-init/k0sctl.yaml.tftpl", {
    controller_ips = multipass_instance.controller[*].ipv4
    worker_ips     = multipass_instance.worker[*].ipv4
    k0s_version    = var.k0s_version
    k0s_api_host   = local.k0s_api_host
    k0s_api_ipv4   = local.k0s_api_ipv4
    ssh_key        = local.ssh_private_key
    ha_mode        = local.ha_mode
  })
}

# --- Post-apply cluster formation — k0sctl (mirrors monitoring's terraform_data.k0s_log_shipper) ---
# k0sctl SSHes to the hosts itself, so it runs from the Mac against the rendered config. Fail-fast
# preflight is the FIRST line (a missing k0sctl otherwise fails `apply` mid-flight with VMs already
# created, and up-connected's consumer loop would swallow the rc=1 and report a "green" broken node).

resource "terraform_data" "k0s_bootstrap" {
  # Re-run whenever any node IP or the rendered k0sctl config changes.
  triggers_replace = concat(
    multipass_instance.controller[*].ipv4,
    multipass_instance.worker[*].ipv4,
    [local_file.k0sctl.content],
  )

  provisioner "local-exec" {
    command = <<-EOT
      command -v k0sctl >/dev/null || { echo "install k0sctl: brew install k0sproject/tap/k0sctl"; exit 1; }
      # OS prep (cloud-init) must finish on every node before k0sctl SSHes in to install k0s.
      for ip in ${join(" ", concat(multipass_instance.controller[*].ipv4, multipass_instance.worker[*].ipv4))}; do
        ssh -n ${local.ssh_opts} ubuntu@"$ip" 'cloud-init status --wait || true'
      done
      # k0sctl distributes PKI + enforces controller->controller->worker ordering itself.
      k0sctl apply --config ${local_file.k0sctl.filename}
    EOT
  }
}

# --- Distribute the admin kubeconfig to every node (depends_on bootstrap) ----
# Its `server:` is already k0s-api.<domain>, so it works from any node once DNS/hosts resolves it.
resource "terraform_data" "k0s_kubeconfig_distribute" {
  depends_on = [terraform_data.k0s_bootstrap]

  triggers_replace = [terraform_data.k0s_bootstrap.id]

  provisioner "local-exec" {
    command = <<-EOT
      k0sctl kubeconfig --config ${local_file.k0sctl.filename} > ${local.render_dir}/kubeconfig
      for ip in ${join(" ", concat(multipass_instance.controller[*].ipv4, multipass_instance.worker[*].ipv4))}; do
        ssh -n ${local.ssh_opts} ubuntu@"$ip" 'mkdir -p /home/ubuntu/.kube'
        scp ${local.ssh_opts} ${local.render_dir}/kubeconfig ubuntu@"$ip":/home/ubuntu/.kube/config
      done
    EOT
  }
}

# --- kube-state-metrics via the k0s manifest deployer (depends_on bootstrap) --
# Applied POST-APPLY (never in cloud-init — an API-dependent step there hangs `multipass launch`
# forever). Dropped into /var/lib/k0s/manifests/<stack>/ on controller-1; the k0s manifest deployer
# reconciles it. hostNetwork Deployment on :8082 (--port) + :8083 (--telemetry-port) — NOT :8080,
# which kube-router already holds on every node (bind collision -> CrashLoopBackOff). KSM defaults
# to :8080 and IGNORES containerPort unless --port/--telemetry-port args are set, so both are pinned
# explicitly. Scrape-target caveat (landed-worker IP) is a monitoring-hub concern — see spec § "KSM
# scrape-targeting caveat".
locals {
  # Single source of truth for the KSM manifest, so a content edit re-triggers the apply below (it
  # rides in triggers_replace). hostNetwork is deliberate (spec): a static node-IP scrape target the
  # external monitoring hub can reach — an ephemeral pod IP would be unscrapable.
  ksm_manifest = <<-YAML
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: kube-state-metrics
      namespace: kube-system
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRole
    metadata:
      name: kube-state-metrics
    rules:
      - apiGroups: [""]
        resources: [configmaps, secrets, nodes, pods, services, serviceaccounts, resourcequotas, replicationcontrollers, limitranges, persistentvolumeclaims, persistentvolumes, namespaces, endpoints]
        verbs: [list, watch]
      - apiGroups: [apps]
        resources: [statefulsets, daemonsets, deployments, replicasets]
        verbs: [list, watch]
      - apiGroups: [batch]
        resources: [cronjobs, jobs]
        verbs: [list, watch]
      - apiGroups: [autoscaling]
        resources: [horizontalpodautoscalers]
        verbs: [list, watch]
      - apiGroups: [networking.k8s.io]
        resources: [ingresses, networkpolicies]
        verbs: [list, watch]
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRoleBinding
    metadata:
      name: kube-state-metrics
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: ClusterRole
      name: kube-state-metrics
    subjects:
      - kind: ServiceAccount
        name: kube-state-metrics
        namespace: kube-system
    ---
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: kube-state-metrics
      namespace: kube-system
      labels: { app.kubernetes.io/name: kube-state-metrics }
    spec:
      replicas: 1
      selector:
        matchLabels: { app.kubernetes.io/name: kube-state-metrics }
      template:
        metadata:
          labels: { app.kubernetes.io/name: kube-state-metrics }
        spec:
          hostNetwork: true
          serviceAccountName: kube-state-metrics
          containers:
            - name: kube-state-metrics
              image: registry.k8s.io/kube-state-metrics/kube-state-metrics:${var.ksm_version}
              args: ["--port=8082", "--telemetry-port=8083"]
              ports:
                - { name: http-metrics, containerPort: 8082, hostPort: 8082 }
                - { name: telemetry, containerPort: 8083, hostPort: 8083 }
              securityContext:
                runAsNonRoot: true
                runAsUser: 65534
    ---
    apiVersion: v1
    kind: Service
    metadata:
      name: kube-state-metrics
      namespace: kube-system
      labels: { app.kubernetes.io/name: kube-state-metrics }
    spec:
      clusterIP: None
      selector: { app.kubernetes.io/name: kube-state-metrics }
      ports:
        - { name: http-metrics, port: 8082, targetPort: 8082 }
        - { name: telemetry, port: 8083, targetPort: 8083 }
  YAML
}

resource "terraform_data" "k0s_ksm_manifest" {
  depends_on = [terraform_data.k0s_bootstrap]

  # Include the manifest content so a ports/args/RBAC edit re-applies on a plain `just up`
  # (ksm_version alone wouldn't change, and the deployer only reconciles a changed file).
  triggers_replace = [
    terraform_data.k0s_bootstrap.id,
    var.ksm_version,
    local.ksm_manifest,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      ssh -n ${local.ssh_opts} ubuntu@${multipass_instance.controller[0].ipv4} \
        'sudo mkdir -p /var/lib/k0s/manifests/kube-state-metrics && cat <<'"'"'KSM'"'"' | sudo tee /var/lib/k0s/manifests/kube-state-metrics/kube-state-metrics.yaml >/dev/null
      ${local.ksm_manifest}
      KSM'
    EOT
  }
}

# --- Cross-cluster DNS/NTP hot-push artifacts (mirrors other clusters) -------
# Discrete per-role renders of the resolver / NTP drop-ins, so a hub IP change can be scp'd onto an
# already-running VM (content-only apply, no recreate) by `just refresh-cross-cluster`. count=0
# keeps a plain `just up` clean.
resource "local_file" "controller_resolved_conf" {
  count    = local.use_dns ? var.k0s_control_plane_count : 0
  filename = "${local.render_dir}/controller-${count.index + 1}-resolved.conf"
  content  = local.dns_resolved_conf
}

resource "local_file" "worker_resolved_conf" {
  count    = local.use_dns ? var.worker_count : 0
  filename = "${local.render_dir}/worker-${count.index + 1}-resolved.conf"
  content  = local.dns_resolved_conf
}

resource "local_file" "haproxy_resolved_conf" {
  count    = local.use_dns && local.ha_mode ? 1 : 0
  filename = "${local.render_dir}/haproxy-resolved.conf"
  content  = local.dns_resolved_conf
}
