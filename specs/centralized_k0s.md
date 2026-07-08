# Spec: centralized_k0s Cluster

> **Status: DRAFT for review.** Synthesized from a 5-agent research fleet (fan-out → fan-in);
> the detailed backing research lives in `specs/centralized_k0s/{ha-loadbalancer,cni-networking,
> provisioning-cloudinit,observability-logging,tooling-shell-repo}.md`. This is the **base spec**
> to iterate on and hand to an adversarial-review round — several cross-shard decisions are
> deliberately left open in [§ Open decisions](#open-decisions-for-review--adversarial-round).
> **Nothing is implemented yet.**

## Context

Today the `centralized_monitoring` cluster carries a **single-node** k0s VM
(`k0s install controller --single`, kine/SQLite, kube-router, unpinned `get.k0s.sh`) that
doubles as a monitored Kubernetes node; `centralized_logging` runs the same single-node shape
for Coroot. This new cluster **extracts k0s into its own `clusters/centralized_k0s/`** and levels
it up to a **production-shaped HA topology** — first on **Multipass** (the cheap arm64-Mac stand-in),
then promoted to **Proxmox**. The prior `ai_docs/claude-multipass-infra-upgrade-brief.md` is
Proxmox-oriented; this spec refines it for Multipass.

**k0s stays in `centralized_monitoring` untouched until this cluster is validated** — no removal
until `just verify centralized_k0s` passes end-to-end.

## Objective

A `just`-orchestrated k0s cluster mirroring every repo convention (auto-discovered by folder name,
runtime-IP-injected cloud-init, two-layer tests, `_shared` opt-ins), providing:

- **3 controller-only + 3 worker VMs**, **etcd** datastore (HA quorum), **no SELinux**.
- **HA control plane** fronted by a load balancer — **external HAProxy** on Multipass (evaluated
  against k0s CPLB/Keepalived + NLLB; see below).
- **k9s, stern, helm, kubectl, etcdctl** on **every** node; the **admin kubeconfig distributed to
  all nodes** so `kubectl` works for the `ubuntu` user everywhere.
- **All exporters + Netdata** on every node (role-aware).
- **All logs shipped to `centralized_logging`** — host + k0s-component logs *and* pod logs.
- **oh-my-zsh** on all nodes with **zsh completions** for `etcd, kubectl, helm, stern, k9s, k0s`.
- **Cilium** evaluated as an opt-in CNI (not the v1 default).

## Architecture

### Topology & resource sizing

**7 VMs total: 3 controllers + 3 workers + 1 HAProxy edge.** Counts and sizes are **tunable vars**
so a laptop can shrink the cluster.

| Role | Count (var) | Each (default) | Notes |
|---|---|---|---|
| controller | `k0s_control_plane_count` = 3 (odd for etcd quorum) | 2 vCPU / 2 G / 20 G | etcd + apiserver + scheduler + controller-manager; **2 G is tight — consider 3 G** (etcd OOM risk, see `specs/centralized-logging-k0s-perf.md`) |
| worker | `k0s_worker_count` = 3 | 2 vCPU / 4 G / 30 G | where pods/kubelet/cAdvisor run |
| haproxy | 1 (implied by LB choice) | 1 vCPU / 1 G / 10 G | L4 TCP passthrough to the 3 controllers |
| **total (default)** | **7** | | **~13 vCPU / ~19 G** |

**The 6-VM k0s footprint (~12 vCPU / 18 G) is essentially the whole Mac budget** the brief cites —
there is **no headroom** for the host or other clusters. Implications: this cluster is likely a
**stand-alone bring-up** and probably **cannot join `just up-connected`** at full size. Laptop
shrink: `k0s_control_plane_count=1, k0s_worker_count=2` → 3 k0s VMs (+haproxy optional) ≈ 6–8 vCPU /
8–10 G; a single controller drops etcd-HA to single-node etcd but fits comfortably. Sizing follows
the `centralized_netbox` `object({cpus,memory,disk})` var idiom.

### Provider & runtime-IP injection

Same edge the repo already uses (`clusters/centralized_logging/main.tf`): **`controller[0]` is
created first** as the IP anchor; its computed `ipv4` feeds `k0s.yaml` SANs and every other node's
join address, forcing OpenTofu to create it before rendering the rest. Providers pin as elsewhere
(`larstobi/multipass ~> 1.4`, `hashicorp/local ~> 2.4`, `required_version >= 1.7`). VMs are
`count`-indexed and 1-named: `centralized-k0s-controller-1..3`, `-worker-1..3`, `-haproxy`
(folder→VM `_`→`-`).

**`hosts` output** (the `tests/testinfra/conftest.py` + Justfile contract) is a dynamic
`{role: {name, ipv4}}` map built from the count-indexed resources — so conftest must generate
per-role fixtures from the keys rather than hard-coding 3 roles:

```hcl
output "hosts" {
  value = merge(
    { for i, c in multipass_instance.controller : "controller-${i + 1}" => { name = c.name, ipv4 = c.ipv4 } },
    { for i, w in multipass_instance.worker     : "worker-${i + 1}"     => { name = w.name, ipv4 = w.ipv4 } },
    { haproxy = { name = multipass_instance.haproxy.name, ipv4 = multipass_instance.haproxy.ipv4 } },
  )
}
```
Also export `k0s_api_endpoint` (the HAProxy IP:6443), `k0s_version`, and any `web_urls`.

### Control-plane HA + load balancer

**Decision: external HAProxy VM** fronting the 3 controllers, with `spec.api.externalAddress` = the
HAProxy IP added to every controller's `spec.api.sans`. The HAProxy VM's own DHCP IP is the single
stable endpoint for kubectl/k9s/CI **and** for worker→API traffic. It passes three TCP ports (L4
passthrough, no TLS termination): **6443** (kube-apiserver), **8132** (konnectivity), **9443** (k0s
controller-join). Config sketch (`mode tcp`, `option tcp-check`, roundrobin over the 3 controllers)
is in `specs/centralized_k0s/ha-loadbalancer.md`.

**Why not k0s-native CPLB/NLLB on Multipass:** CPLB (Keepalived VRRP) needs both a **free in-subnet
VIP** the Multipass dnsmasq won't lease (no reservation API on macOS) *and* **VRRP multicast/GARP**
working across the `vmnet`/QEMU L2 segment — both unverified-to-risky here. NLLB (Envoy) is
internal-only **and is mutually exclusive with `externalAddress`**, so it can't coexist with the
HAProxy path. HAProxy sidesteps the VIP-allocation and multicast unknowns entirely.

**Honest asterisks (adversarial-bait):** the HAProxy VM is a **SPOF** for API reachability (fine for
a lab whose purpose is to rehearse the *etcd* failover drill — it has 3 live backends), and forcing
`externalAddress` **disables NLLB**, so a worker's kubelet/konnectivity depends on HAProxy — an
HAProxy blip hits workers, not just laptops. This makes the lab topology **not** HA-equivalent to the
Proxmox target. See [Proxmox delta](#multipass--proxmox-delta).

### Cluster bootstrap & join

k0s HA needs (a) **ordered join** — controller-1's etcd exists before controllers 2/3 join, then
workers — and (b) **byte-identical CA/SA/etcd-CA keypairs** on all three controllers. Cloud-init has
no cross-VM coordination primitive, so formation happens **post-apply** (join tokens are minted on
controller-1 only after it boots — this cannot be pure-cloud-init). Two models (this is the **#1 open
decision**, see below):

- **Primary — k0sctl (hybrid).** Cloud-init does OS prep only (DNS gate + retryable pinned
  `get.k0s.sh` install + CA trust + tooling); a post-apply `terraform_data` step (mirroring
  `centralized_monitoring`'s `terraform_data.k0s_log_shipper`) renders a `k0sctl.yaml` from
  `tofu output` IPs and runs `k0sctl apply`. **k0sctl distributes the PKI automatically and enforces
  controller→controller→worker order** — the byte-fragile parts live in a tool built for them. Cost:
  a `k0sctl` host-tool preflight (`brew install k0sproject/tap/k0sctl`).
- **Alternative — hand-rolled `terraform_data` SSH.** No extra host tool: SSH to controller-1,
  `k0s token create --role=controller|worker`, scp each token to the matching node, join. Requires
  the repo to own **PKI pre-generation + distribution** (pre-generate CA once and persist like
  `centralized_pki`'s `init_ca.py`, `write_files` into `/var/lib/k0s/pki/**` before `k0s install`) —
  the likeliest thing to silently break a 3-controller join if mismatched.

**Version pin.** Today's k0s is unpinned (fleet-drift risk). Pin `var.k0s_version`
(default **`v1.34.9+k0s.0`** — Kubernetes 1.34.x, etcd 3.6.12, matching the Proxmox brief) and thread
it into `K0S_VERSION` for `get.k0s.sh` and `k0sctl.yaml`. `kubectl` pins to the k8s minor
(`v1.34.x`), `etcdctl` to the bundled etcd — **verify both against `k0s version` in a Phase-0 spike**.
The etcd 3.5→3.6 "zombie member" hop (≥3.5.26 first) only bites a future *in-place* 1.33→1.34 upgrade;
a greenfield 1.34 build is safe — document it in the upgrade runbook.

**Boot-race hardening (×6 exposure).** Every network install carries the repo's verbatim guard —
resolver-ready gate + bounded retry — because `runcmd` is `/bin/sh` with no `set -e`, so a failed
`curl get.k0s.sh` doesn't abort and a later `until … /readyz` loops forever with no `--failed` unit:

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
Any cross-VM wait (e.g. "wait for controller-1 API") must be **bounded** (`for i in $(seq 1 120)`),
never unbounded `until`. The k0sctl model removes cross-VM cloud-init waits entirely (biggest
boot-race reduction).

### CNI / networking

**v1 default: `kuberouter`** (exactly what the repo runs today — zero extra moving parts, arm64-native,
dual-stack-capable, no Helm step). **`enable_cilium` is an opt-in flag for iteration 2** (default
`false`): templates `provider: custom` + `kubeProxy.disabled: true` and Helm-installs Cilium with
`kubeProxyReplacement=true`, `k8sServiceHost=<HAProxy IP>` (the unified LB endpoint), `k8sServicePort=6443`,
`routingMode=tunnel`/`vxlan`. eBPF on Multipass arm64 is **feasible** (real QEMU/HVF VM kernel with BTF
+ cgroup v2 — not the Docker-Desktop trap) but unproven until a VM exists; Cilium's failure mode
(unreachable `k8sServiceHost` at boot → silent networking hang) is exactly the repo's silent-wait-loop
class, so don't couple the first HA bring-up to it. **CNI is immutable post-init** → `enable_cilium`
is a `just recreate`-class flag. `enable_hubble` is a sub-toggle (redundant with `enable_coroot`'s
eBPF). Keep k0s defaults `podCIDR: 10.244.0.0/16`, `serviceCIDR: 10.96.0.0/12` (no collision with
Multipass's `192.168.64.0/24` bridge — **verify per-machine**).

### Node tooling & shell UX

Reuse the existing `install-cli.sh` idiom (arch-substituted GitHub-release download → `/usr/local/bin`).
On **every** node, **unconditional** (no `enable_*` gate — this is the debug baseline):

| Tool | Pin | Notes |
|---|---|---|
| kubectl | `v1.34.x` (match k8s minor) | raw binary from `dl.k8s.io` — a *real* kubectl, not just `k0s kubectl` |
| helm | `v3.21.2` | make **unconditional** (today it's gated inside `coroot-install.sh`) |
| k9s | `v0.51.0` | carry |
| stern | `v1.34.0` | carry (completion flag is `--completion=zsh`, not a subcommand) |
| etcdctl | match bundled etcd | controllers need it; harmless everywhere |

**kubeconfig on all nodes.** Controllers self-generate (`k0s kubeconfig admin`); workers can't. Because
`externalAddress` = HAProxy IP, the generated kubeconfig's `server:` already points at the LB — no
`sed` rewrite. A post-apply `terraform_data.k0s_kubeconfig_distribute` (mirroring `k0s_log_shipper`)
pulls the admin kubeconfig from controller-1 and scps it to `/home/ubuntu/.kube/config` on all nodes.

**oh-my-zsh + completions.** Install unattended in cloud-init as the `ubuntu` user
(`RUNZSH=no CHSH=no KEEP_ZSHRC=yes`), `chsh -s /usr/bin/zsh ubuntu`, and write each tool's completion
into `~/.oh-my-zsh/completions/_<tool>` (already on `fpath` before `compinit`) for
`k0s, kubectl, helm, stern, k9s, etcdctl` — per `docs.k0sproject.io/stable/shell-completion/`. The
oh-my-zsh install curls `raw.githubusercontent.com`, so it must sit **after** the resolver gate.

### Observability — exporters + Netdata

Host exporters everywhere; kubelet/cAdvisor follow the kubelet (workers); etcd + control-plane metrics
on controllers; kube-state-metrics exactly once. Netdata on all 6 (shared snippet unchanged,
`enable_netdata_ebpf` **off** on arm64).

| Exporter | Port | Controllers | Workers | Notes |
|---|---|:---:|:---:|---|
| node_exporter | 9100 | ✅ | ✅ | v1.8.2 |
| systemd_exporter | 9558 | ✅ | ✅ | v0.7.0 |
| process-exporter | 9256 | ✅ | ✅ | v0.8.7 |
| Netdata | 19999 | ✅ | ✅ | shared `install-netdata.sh.tftpl`; Prometheus endpoint |
| kubelet (read-only) | 10255 | ❌ (workload-isolated) | ✅ | `--kubelet-extra-args="--read-only-port=10255"` |
| cAdvisor | 8089 | ❌ | ✅ | v0.49.1 (`:8080` taken by kube-router) |
| kube-state-metrics | 8081 | — one Deployment (cluster-wide) — | | v2.13.0, `hostNetwork`, `replicas: 1` |
| etcd metrics | 2381 | ✅ | ❌ | `--listen-metrics-urls`, HTTP no-cert |
| k0s system-components | 9091 | ✅ (opt-in `--enable-metrics-scraper`) | ❌ | k0s-pushgateway, 2-min TTL → scrape interval < 2 min |

Monitoring-hub Prometheus scrapes via the repo's `extra_scrape_targets` (and `netdata_scrape_targets`
for the `/api/v1/allmetrics` path) — but the **headline requirement is logs → logging**, below.

### Log shipping to centralized_logging

`centralized_logging` ingests **only syslog RFC5424 over TCP :514** (syslog-ng) — it does **not**
speak OTLP and does not run OpenObserve. So:

- **Host + k0s-component logs — already solved.** k0s runs every component as a journald-logged
  systemd service (`k0scontroller`/`k0sworker`), and the shared syslog-ng client drop-in
  (`log_shipping_target`) reads journald → so setting `log_shipping_target` on **all 6 nodes** ships
  OS + control-plane/worker component logs with zero extra work.
- **Pod logs — the gap, bridged.** Pod stdout/stderr goes to `/var/log/pods/*/*/*.log` (containerd/CRI),
  **not** journald. Run **`otelcol-contrib` (v0.117.0, as root) on each worker** with a `filelog/pods`
  receiver (`container` operator) exporting **RFC5424 syslog over TCP → centralized_logging:514** — the
  hub already accepts that framing, **zero hub change**. Config in
  `specs/centralized_k0s/observability-logging.md`. **Caveat:** syslog is a flat line format, so k8s
  metadata (namespace/pod/container) is lossy without a `transform` step and even then flattened; if
  lossless structured pod logs matter, ship those to OpenObserve instead and mirror to logging for
  archival. **Run otelcol as root** or `/var/log/pods` reads fail silently.

### No SELinux

**N/A on Ubuntu.** The k0s SELinux doc applies only to RHEL-family (CentOS/Rocky). Multipass Ubuntu
uses **AppArmor**; k0s's only adjacent need — `apparmor_parser` for containerd — is already present on
stock Ubuntu. No action; note it so a future RHEL Proxmox guest revisits the SELinux doc.

## Layout

```
clusters/centralized_k0s/
├── main.tf                 # count-indexed controller/worker + haproxy VMs; controller[0] anchor;
│                           #   local_file renders of k0s.yaml (per controller) + cloud-inits;
│                           #   terraform_data: k0s_bootstrap (k0sctl OR token-scp) + kubeconfig_distribute
├── variables.tf            # k0s_control_plane_count/worker_count, controller/worker/haproxy size objects,
│                           #   k0s_version, enable_cilium/enable_hubble, enable_netdata(+_ebpf),
│                           #   log_shipping_target, dns_server, internal_ca_cert, ntp_server (all opt-in)
├── outputs.tf              # hosts{}, k0s_api_endpoint, k0s_version, dns_records, web_urls
├── providers.tf, versions.tf, terraform.tfvars
├── cloud-init/
│   ├── controller.yaml.tftpl   # OS prep + DNS gate + pinned get.k0s.sh + tooling + oh-my-zsh + exporters
│   ├── worker.yaml.tftpl       # + kubelet/cAdvisor + otelcol filelog/pods→syslog bridge
│   ├── haproxy.yaml.tftpl      # L4 haproxy.cfg to the 3 controllers
│   ├── k0s.yaml.tftpl          # rendered per controller (node-specific address/peerAddress; shared sans/etcd)
│   └── k0sctl.yaml.tftpl       # (primary model) rendered from tofu output IPs
├── tests/
│   ├── tofu/sizing_and_render.tftest.hcl   # hermetic: mock_provider + command=plan
│   └── testinfra/conftest.py + test_*.py   # live SSH; dynamic per-role fixtures from hosts{}
└── docs/feature-flags.md
```
Shared snippets referenced from `clusters/_shared/cloud-init/` (netdata, syslog-client, otel-agent,
use-dns, use-ntp, issue-cert) — the documented per-cluster-vendoring exception.

## Testing — layered feedback loop

Mirror the repo's two-layer split; pin cross-cluster opt-ins (`dns_server`, `internal_ca_cert`,
`ntp_server`, `enable_cilium`) **OFF** in each test file's file-level `variables {}` (auto-tfvars gotcha).

- **Hermetic** (`tofu test`, `mock_provider "multipass" {}`, `command = plan`, `strcontains`/`yamldecode`
  — `just check`): default counts render 3 controllers + 3 workers (+haproxy) at the right sizes;
  a `k0s_control_plane_count=1, k0s_worker_count=2` run yields 3 k0s VMs (laptop mode); controller
  `k0s.yaml` carries `storage.type: etcd` + `externalAddress`/`sans` with the (mock) HAProxy IP;
  every node's cloud-init contains the pinned tool installs, `K0S_VERSION`, oh-my-zsh + `_<tool>`
  completions, `chsh zsh`; the kubeconfig-distribute + bootstrap `terraform_data` exist; `_off_by_default`
  asserts for `enable_cilium`/`log_shipping_target`.
- **Live** (`tests/testinfra/` over SSH — `just verify`): each controller `sudo k0s status` Running;
  `sudo k0s kubectl get nodes` = **6 Ready**; `sudo k0s etcd member-list` = 3 members; failover drill
  (hard-stop the active controller → API stays 200 via HAProxy, etcd keeps quorum 2/3); **standalone
  `kubectl get nodes` works as `ubuntu` on all nodes incl. workers** (kubeconfig-distribution proof);
  k9s/stern/helm/kubectl/etcdctl present; `ubuntu` shell is zsh with completions; log-shipping present.

## Quickstart

```sh
just check   centralized_k0s   # hermetic (no VMs)
just up      centralized_k0s   # apply → 7 VMs; then k0sctl/token bootstrap forms the cluster
just verify  centralized_k0s   # live testinfra over SSH
just ssh     centralized_k0s controller-1   # then: k9s / kubectl / sudo k0s kubectl get nodes
just recreate centralized_k0s  # after ANY cloud-init/k0s.yaml edit (not `just up`)
```
`just up-connected` may not fit this cluster at full size (budget) — treat as stand-alone or shrink.

## Applying cloud-init / config changes

OpenTofu does not recreate a `multipass_instance` when only rendered `local_file` content changes, so
**edit cloud-init/`k0s.yaml` → `just recreate centralized_k0s`**, never `just up` (else stale cloud-init,
live tests fail confusingly). Iterate on a running cluster via SSH + `systemctl restart --no-block`,
then fold the fix back into the `.tftpl`.

## Open decisions (for review + adversarial round)

1. **Bootstrap model: k0sctl (primary) vs hand-rolled `terraform_data` SSH.** k0sctl handles PKI +
   join order but adds a host-tool preflight and a non-`mock_provider`-testable apply; the hand-rolled
   path keeps everything in-repo but must own PKI pre-generation (the likeliest silent-failure point).
2. **HAProxy SPOF & lost NLLB.** Accept a single-VM chokepoint in front of an "HA" control plane for
   the lab? It makes the topology **not** HA-equivalent to the Proxmox target (where CPLB+NLLB return).
   Alternative: spike CPLB `unicast` VRRP + a hand-picked high VIP to see if it works on Multipass at all.
3. **Controller RAM.** 2 G risks etcd OOM (cf. `specs/centralized-logging-k0s-perf.md`) — bump to 3 G,
   or default to 1 controller on laptops?
4. **Does this cluster ever join `up-connected`?** At 13 vCPU / 19 G it likely can't coexist — is it
   permanently stand-alone, or do we ship a smaller default and treat 3+3 as an explicit opt-in?
5. **Pod-log metadata loss** through the syslog bridge — acceptable, or do pods need OpenObserve
   (structured) with syslog only for archival?
6. **k0s version pin** (`v1.34.9+k0s.0`) + kubectl/etcdctl pins — confirm against `k0s version` in a spike.

## Future work (kept in mind, not built here)

- **CPLB (Keepalived VIP) + NLLB** on the Proxmox promotion (reservable VIP, real multicast) — a config
  edit, not a rebuild, since etcd/tokens/PKI are unchanged.
- **Cilium + Hubble** as `enable_cilium` iteration 2.
- **Storage/CSI** (k0s ships none): OpenEBS/local-path; kubelet dir is `/var/lib/k0s/kubelet`.
- **Backup/DR**: `k0s backup` (etcd + PKI, **not** PVs) + Velero for PV data (Proxmox-era).
- **Manifest deployer / `spec.extensions.helm`** for addons instead of ad-hoc `runcmd kubectl`.
- **Internal-CA TLS** for any exposed k0s dashboards (mirror `centralized_monitoring` Phase 2).

## Sources

Backing research (this repo): `specs/centralized_k0s/{ha-loadbalancer,cni-networking,
provisioning-cloudinit,observability-logging,tooling-shell-repo}.md` — each with its own k0s-doc
citations and self-adversarial section. Prior Proxmox brief: `ai_docs/claude-multipass-infra-upgrade-brief.md`.
Repo templates: `clusters/centralized_logging/` (k0s + Coroot + `local.k0s_size`),
`clusters/centralized_monitoring/` (k0s exporters + `terraform_data.k0s_log_shipper` + otel pod-logs),
`clusters/centralized_netbox/` (cluster anatomy). k0s docs: `https://docs.k0sproject.io/stable/`.
