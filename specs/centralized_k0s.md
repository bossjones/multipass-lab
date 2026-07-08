# Spec: centralized_k0s Cluster

> **Status: DRAFT — decisions locked after review round 1.** Synthesized from a 5-agent research
> fleet (fan-out → fan-in); detailed backing research in `specs/centralized_k0s/{ha-loadbalancer,
> cni-networking,provisioning-cloudinit,observability-logging,tooling-shell-repo}.md`. This revision
> folds in the user's review (Vector, k0sctl, `--enable-worker` controllers, smaller default,
> blackbox, native HAProxy exporter, roxy-wi deferral). **Nothing is implemented yet** — next is an
> adversarial round, then implementation.

## Context

Today the `centralized_monitoring` cluster carries a **single-node** k0s VM
(`k0s install controller --single`, kine/SQLite, kube-router, unpinned `get.k0s.sh`) that doubles
as a monitored Kubernetes node; `centralized_logging` runs the same shape for Coroot. This new
cluster **extracts k0s into its own `clusters/centralized_k0s/`** and levels it up to a
**production-shaped HA topology** — first on **Multipass** (arm64-Mac stand-in), then promoted to
**Proxmox**. The prior `ai_docs/claude-multipass-infra-upgrade-brief.md` is Proxmox-oriented; this
spec refines it for Multipass. **k0s stays in `centralized_monitoring` untouched until this cluster
is validated** (`just verify centralized_k0s` green).

## Objective

A `just`-orchestrated k0s cluster mirroring every repo convention (folder-name auto-discovery,
runtime-IP-injected cloud-init, two-layer tests, `_shared` opt-ins), providing:

- **Tunable topology** — default **1 controller + 2 workers** (fits `up-connected`); **3 controllers
  + 3 workers + HAProxy** HA as an explicit opt-in; **etcd** datastore, **no SELinux**.
- **HA control plane** fronted by **external HAProxy** (evaluated against k0s CPLB/Keepalived + NLLB),
  **conditional** on >1 controller, exposing its **native Prometheus exporter** on `:8405`.
- **k9s, stern, helm, kubectl, etcdctl** on every node; **admin kubeconfig distributed to all nodes**.
- **kubelet + cAdvisor on controllers too** (via `--enable-worker`, control-plane taint kept) plus
  the full exporter + **Netdata** set, role-aware; **blackbox exporter** on the monitoring hub.
- **All logs → `centralized_logging`** via **Vector** (host/k0s-component as syslog; pod logs
  structured to the monitoring hub's OpenObserve + a syslog archival copy to logging).
- **oh-my-zsh** on all nodes with zsh completions for `etcd, kubectl, helm, stern, k9s, k0s`.
- **Cilium** as an opt-in CNI (`enable_cilium`, iteration 2 — not the v1 default).
- **Cluster formation by k0sctl** now; **Ansible** (your `ansible-dev` plugin) migrates the
  node-config layer later.

## Architecture

### Topology & resource sizing

**Node counts are `count`-driven vars.** The control-plane count decides HA *and* whether HAProxy
is provisioned (a VIP/LB is meaningless with one controller).

| Mode | controllers | workers | HAProxy | VMs | ~vCPU / RAM | etcd |
|---|---|---|---|---|---|---|
| **Default** (`up-connected`-fit) | 1 | 2 | ❌ (direct to controller-1) | 3 | ~6 / 8–10 G | single-node |
| **HA opt-in** (`k0s_control_plane_count=3`) | 3 | 3 | ✅ | 7 | ~13 / 19 G | 3-member quorum |

Per-VM sizing (tunable `object({cpus,memory,disk})` vars):

| Role | Each | Notes |
|---|---|---|
| controller | **3 vCPU / 3 G / 20 G** | etcd + apiserver + scheduler + controller-manager + (now) kubelet/cAdvisor via `--enable-worker`. 3 G for etcd OOM headroom (cf. `specs/centralized-logging-k0s-perf.md`). |
| worker | 2 vCPU / 4 G / 30 G | pods/kubelet/cAdvisor |
| haproxy | 1 vCPU / 1 G / 10 G | only when controllers > 1; L4 passthrough + `:8405` exporter |

The **HA opt-in (~13 vCPU / 19 G) is essentially the whole Mac** — bring it up **stand-alone**, not
alongside the fleet. `up-connected` uses the 3-VM default so the cluster coexists with the rest.

### Provider & runtime-IP injection

`controller[0]` is created first as the IP anchor (same edge as `centralized_logging`); its `ipv4`
feeds `k0s.yaml` SANs and every node's join address, forcing create-before-render. Providers pin as
elsewhere (`larstobi/multipass ~> 1.4`, `hashicorp/local ~> 2.4`, `required_version >= 1.7`).
`count`-indexed, 1-named VMs: `centralized-k0s-controller-1..N`, `-worker-1..M`, `-haproxy`
(folder→VM `_`→`-`).

**`hosts` output** — dynamic `{role:{name,ipv4}}` built from the count-indexed resources (HAProxy
conditional, like `centralized_netbox`'s count-gated `agent`):

```hcl
output "hosts" {
  value = merge(
    { for i, c in multipass_instance.controller : "controller-${i + 1}" => { name = c.name, ipv4 = c.ipv4 } },
    { for i, w in multipass_instance.worker     : "worker-${i + 1}"     => { name = w.name, ipv4 = w.ipv4 } },
    var.k0s_control_plane_count > 1 ? { haproxy = { name = multipass_instance.haproxy[0].name, ipv4 = multipass_instance.haproxy[0].ipv4 } } : {},
  )
}
```
Also export `k0s_api_endpoint` (HAProxy IP if present, else controller-1 IP), `k0s_version`,
`dns_records`, `web_urls`.

### Control-plane HA + load balancer (HAProxy, conditional)

When `k0s_control_plane_count > 1`, an **HAProxy VM** fronts the controllers; `spec.api.externalAddress`
= the HAProxy IP (added to every controller's `spec.api.sans`). It passes three TCP ports (L4
passthrough, no TLS termination): **6443** (apiserver), **8132** (konnectivity), **9443** (controller
join). With a single controller, `externalAddress` = controller-1 IP and no HAProxy is created.

**Native Prometheus metrics** — HAProxy's built-in exporter (no sidecar), scraped by the monitoring
hub at `haproxy:8405/metrics`:

```haproxy
frontend prometheus
  bind :8405
  mode http
  http-request use-service prometheus-exporter if { path /metrics }
  no log
# ... plus mode tcp frontends/backends on 6443/8132/9443 → the 3 controllers (option tcp-check) ...
```

**Why not k0s-native CPLB/NLLB on Multipass:** CPLB (Keepalived VRRP) needs a free in-subnet VIP the
Multipass dnsmasq won't lease *and* VRRP multicast/GARP across the `vmnet` segment — both
unverified-to-risky; NLLB is internal-only and mutually exclusive with `externalAddress`. HAProxy
makes the endpoint a boring DHCP IP. **Asterisks:** HAProxy is a **SPOF** for API reachability (fine
for a lab whose drill exercises *etcd* failover with 3 live backends) and forcing `externalAddress`
disables NLLB, so the lab topology is **not** HA-equivalent to the Proxmox target — where CPLB+NLLB
return (a config edit, not a rebuild). Details in `specs/centralized_k0s/ha-loadbalancer.md`.
**roxy-wi** (an HAProxy management UI) is deferred — it's **x86_64-only** (won't run on arm64
Multipass) and needs its own server+DB+agents; declarative cloud-init HAProxy + the native exporter
cover the lab. See Future work.

### Cluster bootstrap & join — k0sctl

**Decision: k0sctl (hybrid).** Cloud-init does OS prep only — DNS warm-up gate + retryable **pinned**
`get.k0s.sh` install + CA trust + tooling + Vector/exporters — and **does not** run `k0s install`. A
post-apply `terraform_data.k0s_bootstrap` (mirroring `centralized_monitoring`'s
`terraform_data.k0s_log_shipper`) renders `k0sctl.yaml` from `tofu output` IPs and runs `k0sctl apply`.
k0sctl **distributes the PKI automatically** and enforces controller→controller→worker order — the
byte-fragile parts live in a tool built for them, and no controller's cloud-init waits on a peer
(biggest boot-race reduction). Cost: a `k0sctl` host-tool preflight (`brew install
k0sproject/tap/k0sctl`) — added to the `just` preflight like `tofu`/`multipass`/`uv`.

*Ansible is deliberately not used for bootstrap* — k0sctl already is "Ansible-for-k0s" (SSH-driven
PKI + join). **Ansible enters later**: once your `ansible-dev` plugin (`boss-skills/specs/
ansible-dev-plugin.md`) lands, migrate the **node-config layer** (tooling, oh-my-zsh, Vector,
exporters, kubeconfig fan-out) from cloud-init/`terraform_data` to Ansible roles — this cluster is a
natural first consumer (its Multipass-live-VM test rung). See Future work.

**Version pin.** Today's k0s is unpinned. Pin `var.k0s_version` (default **`v1.34.9+k0s.0`** —
Kubernetes 1.34.x, etcd 3.6.12) threaded into `K0S_VERSION` (`get.k0s.sh`) and `k0sctl.yaml`'s
`spec.k0s.version`; `kubectl` pins to the k8s minor, `etcdctl` to the bundled etcd — **verify all
three against `k0s version` in the Phase-0 spike**. The etcd 3.5→3.6 "zombie member" hop (≥3.5.26
first) only bites a future in-place 1.33→1.34 upgrade — document in the upgrade runbook.

**Boot-race hardening.** Repo's verbatim guard (resolver-ready gate + bounded retry) on every network
install, because `runcmd` is `/bin/sh` with no `set -e`:

```yaml
%{ if dns_server != "" ~}
  - systemctl restart systemd-resolved
  - |
    for i in $(seq 1 30); do getent hosts get.k0s.sh >/dev/null 2>&1 && break; sleep 2; done
%{ endif ~}
  - |
    for i in $(seq 1 5); do
      curl -sSLf https://get.k0s.sh | K0S_VERSION=${k0s_version} sh && break
      echo "k0s install attempt $i failed; retrying"; sleep 5
    done
```

### CNI / networking

**v1 default `kuberouter`** (what the repo runs today — zero extra steps, arm64-native, dual-stack).
**`enable_cilium` opt-in for iteration 2** (default `false`): `provider: custom` +
`kubeProxy.disabled: true` + Helm Cilium with `kubeProxyReplacement=true`,
`k8sServiceHost=<k0s_api_endpoint>` (HAProxy IP, or controller-1 in single mode), `routingMode=tunnel/vxlan`.
eBPF on Multipass arm64 is feasible (real QEMU/HVF VM kernel, BTF + cgroup v2 — not the Docker-Desktop
trap) but unproven until a VM exists; Cilium's unreachable-`k8sServiceHost` failure is exactly the
silent-wait-loop class, so don't couple the first HA bring-up to it. CNI is immutable post-init →
`enable_cilium` is a `just recreate`-class flag. Keep k0s defaults `podCIDR: 10.244.0.0/16`,
`serviceCIDR: 10.96.0.0/12` (no collision with Multipass's `192.168.64.0/24` — verify per-machine).

### Node tooling & shell UX

Reuse `install-cli.sh` (arch-substituted release download → `/usr/local/bin`). On **every** node,
**unconditional** (debug baseline): **kubectl** (`v1.34.x`, real binary not just `k0s kubectl`),
**helm** `v3.21.2` (make unconditional — today gated in `coroot-install.sh`), **k9s** `v0.51.0`,
**stern** `v1.34.0` (completion flag `--completion=zsh`), **etcdctl** (match bundled etcd).

**kubeconfig on all nodes.** Controllers self-generate (`k0s kubeconfig admin`); workers can't.
Because `externalAddress` = `k0s_api_endpoint`, the generated kubeconfig's `server:` already points
at the LB/controller — no `sed`. Post-apply `terraform_data.k0s_kubeconfig_distribute` pulls it from
controller-1 and scps to `/home/ubuntu/.kube/config` on all nodes. (k0sctl also writes an admin
kubeconfig back to the Mac — usable for `just`-side checks.)

**oh-my-zsh + completions.** Unattended install as `ubuntu` (`RUNZSH=no CHSH=no KEEP_ZSHRC=yes`),
`chsh -s /usr/bin/zsh ubuntu`, one `~/.oh-my-zsh/completions/_<tool>` per `k0s, kubectl, helm, stern,
k9s, etcdctl` (on `fpath` before `compinit`). The oh-my-zsh curl of `raw.githubusercontent.com` sits
**after** the resolver gate.

### Observability — exporters + Netdata + blackbox

**Controllers now run kubelet + cAdvisor** (via `k0s install controller --enable-worker`, keeping the
default control-plane taint so no user pods schedule) — so those metrics *and* pod logs exist on
controllers too. Host exporters everywhere; kube-state-metrics exactly once; etcd + k0s
system-component metrics on controllers.

| Exporter | Port | Controllers | Workers | Notes |
|---|---|:---:|:---:|---|
| node_exporter | 9100 | ✅ | ✅ | v1.8.2 |
| systemd_exporter | 9558 | ✅ | ✅ | v0.7.0 |
| process-exporter | 9256 | ✅ | ✅ | v0.8.7 |
| Netdata | 19999 | ✅ | ✅ | shared `install-netdata.sh.tftpl`; `enable_netdata_ebpf` **off** on arm64 |
| kubelet (read-only) | 10255 | ✅ (now, via `--enable-worker`) | ✅ | `--kubelet-extra-args="--read-only-port=10255"` |
| cAdvisor | 8089 | ✅ (now) | ✅ | v0.49.1 (`:8080` = kube-router) |
| kube-state-metrics | 8081 | — one cluster-wide Deployment (v2.13.0, hostNetwork, replicas 1) — | | |
| etcd metrics | 2381 | ✅ | ❌ | `--listen-metrics-urls`, HTTP no-cert |
| k0s system-components | 9091 | ✅ (opt-in `--enable-metrics-scraper`) | ❌ | k0s-pushgateway, 2-min TTL → scrape < 2 min |
| **HAProxy** | 8405 | — HAProxy VM (HA mode) — | | native `prometheus-exporter` service |

**Blackbox exporter — on the monitoring hub.** Run `blackbox_exporter` on `centralized_monitoring`
(next to Prometheus, the standard pattern) and add scrape jobs (with `params`/relabeling) that probe:
the k0s API `https://<k0s_api_endpoint>:6443/readyz`, HAProxy stats, and key service URLs. This is a
change to `centralized_monitoring` (new exporter + scrape jobs), consumed via the existing
`extra_scrape_targets` mechanism; centralized_k0s just exposes the endpoints.

### Log shipping to centralized_logging — Vector

**Vector replaces the syslog-ng client drop-in *and* the otelcol pod bridge with one agent per node.**
`centralized_logging` ingests only syslog RFC5424/TCP:514, so:

- **Host + k0s-component logs** — Vector `journald` source → **`syslog` sink** (RFC5424/TCP) →
  `centralized_logging:514`. k0s runs every component as a journald systemd service
  (`k0scontroller`/`k0sworker`), so OS + control-plane/worker component logs ship with zero hub change.
- **Pod logs (structured, metadata-preserving)** — Vector `kubernetes_logs` (or file source on
  `/var/log/pods/*/*/*.log`, present on all nodes now that controllers run kubelet) → **VRL transforms**
  (parse, enrich `k8s.namespace/pod/container`, redact) → **two sinks**: (a) the monitoring hub's
  **OpenObserve** (`http`/OTLP sink → `/api/<org>/<stream>/_json`, full structured metadata — solves
  the syslog metadata-loss problem), and (b) a flat **`syslog` copy** to `centralized_logging` for
  archival. Runs as root to read `/var/log/pods`.
- Var plumbing: reuse `log_shipping_target` (→ centralized_logging syslog) + `openobserve_endpoint`/
  `openobserve_org`/`openobserve_password` (→ monitoring OpenObserve) — both already standard
  cross-cluster opt-in vars, so `up-connected` wires them from live hub IPs.

**Watch-outs:** back-pressure — cap the OpenObserve firehose and size Vector's disk buffer; the
syslog copy is lossy by design (archival only — structured queries go to OpenObserve); Vector on
arm64 is fine (native). Config sketch to be written under `cloud-init/vector/`.

### No SELinux

**N/A on Ubuntu** (AppArmor). The k0s SELinux doc is RHEL-only; the only adjacent need
(`apparmor_parser` for containerd) is present on stock Ubuntu. Note it for a future RHEL Proxmox guest.

## Layout

```
clusters/centralized_k0s/
├── main.tf                 # count-indexed controller/worker + conditional haproxy; controller[0] anchor;
│                           #   local_file renders of k0s.yaml (per controller) + cloud-inits + k0sctl.yaml;
│                           #   terraform_data: k0s_bootstrap (k0sctl apply) + kubeconfig_distribute
├── variables.tf            # k0s_control_plane_count(=1)/worker_count(=2), controller/worker/haproxy sizes,
│                           #   k0s_version, enable_cilium/enable_hubble, enable_netdata(+_ebpf),
│                           #   log_shipping_target, openobserve_endpoint/org/password,
│                           #   dns_server, internal_ca_cert, ntp_server (all opt-in)
├── outputs.tf              # hosts{}, k0s_api_endpoint, k0s_version, dns_records, web_urls
├── providers.tf, versions.tf, terraform.tfvars
├── cloud-init/
│   ├── controller.yaml.tftpl   # OS prep + DNS gate + pinned get.k0s.sh + tooling + oh-my-zsh + exporters + Vector
│   ├── worker.yaml.tftpl       # + kubelet/cAdvisor
│   ├── haproxy.yaml.tftpl      # L4 haproxy.cfg + :8405 prometheus frontend
│   ├── k0s.yaml.tftpl          # per controller (node-specific address/peerAddress; shared sans/etcd; --enable-worker)
│   ├── k0sctl.yaml.tftpl       # rendered from tofu output IPs
│   └── vector/vector.toml.tftpl# journald→syslog + kubernetes_logs→OpenObserve(+syslog copy)
├── tests/
│   ├── tofu/sizing_and_render.tftest.hcl   # hermetic: mock_provider + command=plan
│   └── testinfra/conftest.py + test_*.py   # live SSH; dynamic per-role fixtures from hosts{}
└── docs/feature-flags.md
```
Shared snippets from `clusters/_shared/cloud-init/` (netdata, use-dns, use-ntp, issue-cert).

## Testing — layered feedback loop

Two-layer split; pin cross-cluster opt-ins (`dns_server`, `internal_ca_cert`, `ntp_server`,
`enable_cilium`, `openobserve_endpoint`, `log_shipping_target`) **OFF** in each test file's file-level
`variables {}` (auto-tfvars gotcha).

- **Hermetic** (`tofu test`, `mock_provider`, `command = plan`, `strcontains`/`yamldecode` — `just
  check`): default renders 1 controller + 2 workers, **no HAProxy**; a `k0s_control_plane_count=3`
  run renders 3 controllers + 3 workers **+ HAProxy** at the right sizes (controller 3 vCPU/3 G); the
  HAProxy cloud-init contains the `:8405 prometheus-exporter` frontend; controller `k0s.yaml` carries
  `storage.type: etcd`, `--enable-worker`, `externalAddress`/`sans` with the (mock) endpoint; every
  node's cloud-init has the pinned tool installs, `K0S_VERSION`, oh-my-zsh + `_<tool>` completions,
  `chsh zsh`, and the **Vector** config (journald→syslog, kubernetes_logs→OpenObserve); `k0sctl.yaml`
  + the `k0s_bootstrap`/`kubeconfig_distribute` `terraform_data` exist; `_off_by_default` for
  `enable_cilium`/`log_shipping_target`/`openobserve_endpoint`.
- **Live** (`tests/testinfra/` over SSH — `just verify`): each controller `sudo k0s status` Running;
  `sudo k0s kubectl get nodes` = all Ready (3 default / 6 HA); in HA mode `sudo k0s etcd member-list`
  = 3 + failover drill (hard-stop active controller → API 200 via HAProxy, quorum 2/3); standalone
  `kubectl get nodes` works as `ubuntu` on every node (kubeconfig-distribution proof); tools present;
  `ubuntu` shell = zsh with completions; **Vector** running + shipping (syslog line lands in
  `/var/log/remote/` on central; a pod-log record appears in OpenObserve); HAProxy `:8405/metrics`
  returns `haproxy_*` (HA mode); blackbox probe of `/readyz` is up (asserted on the monitoring hub).

## Quickstart

```sh
just check   centralized_k0s                       # hermetic (no VMs)
just up      centralized_k0s                        # default 1+2; k0sctl bootstrap forms the cluster
K0S_HA=1 just up centralized_k0s                    # (or set k0s_control_plane_count=3) → 3+3+HAProxy, stand-alone
just verify  centralized_k0s
just ssh     centralized_k0s controller-1           # k9s / kubectl / sudo k0s kubectl get nodes
just recreate centralized_k0s                       # after ANY cloud-init/k0s.yaml edit (not `just up`)
```
Preflight: `k0sctl` must be on the Mac (`brew install k0sproject/tap/k0sctl`) — add to the `just`
tool check. The default 1+2 joins `up-connected`; the 3+3 HA opt-in is a stand-alone bring-up.

## Applying cloud-init / config changes

Edit cloud-init/`k0s.yaml`/`vector.toml` → **`just recreate centralized_k0s`**, never `just up`
(stale-cloud-init trap). Iterate live via SSH + `systemctl restart --no-block`, then fold back into
the `.tftpl`.

## Decisions locked (review round 1)

| Topic | Decision |
|---|---|
| Bootstrap | **k0sctl** now (PKI + join order); Ansible/`ansible-dev` migrates node-config later |
| Log shipping | **Vector** per node; pods→OpenObserve (structured) + syslog→logging; host/component→syslog→logging |
| Controllers | `--enable-worker` **with taint kept** → kubelet + cAdvisor + pod logs, no user pods |
| Default size | **1 CP + 2 workers** (fits `up-connected`); **3+3 + HAProxy** = HA opt-in, stand-alone |
| HAProxy | conditional on >1 controller; native Prometheus exporter on `:8405`; stays (no CPLB spike) |
| Controller RAM | **3 G** (etcd OOM headroom) |
| Blackbox | on the **monitoring hub**, probing `/readyz` + HAProxy + services |
| roxy-wi | **deferred** to Proxmox (x86_64-only) |
| CNI | kube-router v1; `enable_cilium` opt-in iteration 2 |

**Phase-0 spike checklist (verify on a live VM before committing pins):** `k0s version` → confirm
`k0s_version` / `kubectl` / `etcdctl` pins; `ls /sys/kernel/btf/vmlinux` + cgroup v2 (Cilium readiness);
Multipass bridge subnet (podCIDR/serviceCIDR collision); Vector `kubernetes_logs`→OpenObserve auth path.

## Future work (kept in mind, not built here)

- **Ansible / `ansible-dev` plugin** migrates the node-config layer (tooling, Vector, exporters,
  kubeconfig) once the plugin lands — this cluster as its first real consumer.
- **CPLB (Keepalived VIP) + NLLB** on Proxmox (reservable VIP, real multicast) — a config edit, not
  a rebuild (etcd/tokens/PKI unchanged).
- **roxy-wi** as the HAProxy management UI on the x86_64 Proxmox promotion.
- **Cilium + Hubble** (`enable_cilium` iteration 2).
- **Storage/CSI** (k0s ships none): OpenEBS/local-path; kubelet dir `/var/lib/k0s/kubelet`.
- **Backup/DR**: `k0s backup` (etcd + PKI, not PVs) + Velero for PV data (Proxmox-era).
- **Manifest deployer / `spec.extensions.helm`** for addons vs ad-hoc `runcmd kubectl`.

## Sources

Backing research: `specs/centralized_k0s/{ha-loadbalancer,cni-networking,provisioning-cloudinit,
observability-logging,tooling-shell-repo}.md` (each with k0s-doc citations + self-adversarial
section). Prior Proxmox brief: `ai_docs/claude-multipass-infra-upgrade-brief.md`. Ansible direction:
`boss-skills/specs/ansible-dev-plugin.md`. Repo templates: `clusters/centralized_logging/`,
`clusters/centralized_monitoring/`, `clusters/centralized_netbox/`. k0s docs:
`https://docs.k0sproject.io/stable/`.
