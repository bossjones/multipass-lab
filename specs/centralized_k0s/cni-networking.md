# centralized_k0s — CNI / Networking research

_Shard: `cni-networking`. Scope: pick the CNI for a 3-controller + 3-worker etcd-HA k0s
cluster on arm64 Multipass Ubuntu VMs (macOS host), deciding **kube-router (default) vs
Cilium+Hubble** before build — CNI is immutable after cluster init in k0s._

## Summary

- **Recommendation: ship v1 on the k0s default `kuberouter` CNI** (exactly what
  `centralized_logging` already runs today via `k0s install controller --single`, no
  network override). It is byte-simple, arm64-native, ~15% lighter, dual-stack-capable
  out of the box, and needs no Helm step or API-server-reachability choreography.
- **Add `enable_cilium` as an opt-in flag for a 2nd iteration**, not v1. Cilium +
  kube-proxy replacement + Hubble is technically feasible on Multipass arm64 (the guest
  is a real QEMU/HVF VM with a real Ubuntu kernel that ships BTF + cgroup v2 — this is
  **not** the Docker-Desktop nested-container trap), but it adds a Helm install, an
  `k8sServiceHost` that must point at the CPLB VIP (coupling to the HA shard), heavier
  per-VM footprint, and a genuinely harder failure surface. Prove the base HA cluster on
  kube-router first, then flip Cilium on as a clean rebuild.
- **The immutability constraint is the whole reason this is a pre-build decision.** k0s
  docs: _"Once you initialize the cluster with a network provider the only way to change
  providers is through a full cluster redeployment."_ So `enable_cilium` is a
  `just recreate`-class flag (rebuild), never a `just up` mutate — mirror the existing
  `enable_coroot` cloud-init-flag pattern.

## kube-router vs Cilium (on k0s)

| Dimension | **kube-router** (`provider: kuberouter`, default) | **Cilium** (`provider: custom`) |
|---|---|---|
| How selected in k0s | Default; or explicit `spec.network.provider: kuberouter`. k0s **bundles + manages** the deployment. | `spec.network.provider: custom` → k0s **opts out** of managing the CNI; you Helm-install Cilium yourself. |
| kube-proxy | On (k0s-managed). | Disable it: `spec.network.kubeProxy.disabled: true`, then Helm `--set kubeProxyReplacement=true` (eBPF replaces it). |
| API-server reachability | N/A — kube-proxy provides the in-cluster `kubernetes` Service before CNI is up. | **Chicken-and-egg**: with kube-proxy gone, Cilium needs the real API endpoint at install. Set `--set k8sServiceHost=<VIP>` `--set k8sServicePort=6443`. blog: _"Use the controller node IP or load balancer address, not 127.0.0.1"_ → **must point at the CPLB VIP from the HA shard**. |
| Datapath | BGP-based, no overlay (native routing); ~15% fewer resources per k0s docs. | eBPF datapath; here use `routingMode=tunnel` + `tunnelProtocol=vxlan` (safe default on Multipass DHCP L2), `ipam.mode=kubernetes` to match k0s podCIDR. |
| Dual-stack | Works **out of the box** with k0s dual-stack config. | k0s configures its own components; the custom CNI must be configured separately for v6. |
| Observability | Standard metrics only. | **Hubble** L3–L7 flow visibility + Hubble UI (see below). |
| Windows nodes | Not supported (irrelevant here). | Supported (irrelevant here). |
| Operational cost | Zero extra steps — turnkey with `k0s install`. | Helm release + version pin + VIP coupling + heavier agents/operator DaemonSet. |

Example k0s network stanzas (custom/Cilium path, aligned with the oneuptime blog):

```yaml
# kube-router (v1 default — effectively what the repo does today)
spec:
  network:
    provider: kuberouter
    podCIDR: 10.244.0.0/16
    serviceCIDR: 10.96.0.0/12
```

```yaml
# Cilium (opt-in, 2nd iteration)
spec:
  network:
    provider: custom
    podCIDR: 10.244.0.0/16
    serviceCIDR: 10.96.0.0/12
    kubeProxy:
      disabled: true
```

```bash
# then, after nodes are up (VIP from the HA shard):
helm install cilium cilium/cilium --version 1.19.x -n kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=${CPLB_VIP} --set k8sServicePort=6443 \
  --set ipam.mode=kubernetes \
  --set routingMode=tunnel --set tunnelProtocol=vxlan \
  --set operator.replicas=1        # resource-constrained lab VMs
# verify:
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep KubeProxyReplacement
```

## eBPF-on-Multipass feasibility (arm64, macOS host) — the risk, reasoned

**Verdict: feasible, low-to-moderate risk.** Reasoning, explicit:

1. **Multipass guests are real VMs, not nested containers.** On Apple Silicon, Multipass
   runs the Ubuntu cloud image under QEMU accelerated by the macOS Hypervisor.framework
   (HVF) — a full arm64 Linux kernel, not a shared/namespaced host kernel. This is the
   critical difference from Docker Desktop, where Cilium's eBPF features are commonly
   blocked. A real VM kernel means real eBPF program loading, tc/XDP hooks, and BPF maps.
2. **BTF / CO-RE is present.** Ubuntu ships `CONFIG_DEBUG_INFO_BTF=y` and
   `/sys/kernel/btf/vmlinux` on its generic arm64 kernels (5.8+; the 22.04/24.04 images
   Multipass launches are on 5.15/6.8). Cilium's CO-RE loader needs exactly this; no
   custom kernel build required. (Confirm on a live VM with
   `ls -l /sys/kernel/btf/vmlinux`.)
3. **cgroup v2** is the default unified hierarchy on Ubuntu 22.04+ — what Cilium's
   socket-LB / kube-proxy-replacement attaches to. (Confirm: `stat -fc %T /sys/fs/cgroup`
   → `cgroup2fs`.)
4. **Kernel floor is met.** Cilium wants 5.4+ (5.10+ recommended per the oneuptime blog:
   _"Linux nodes with kernel 5.10+ or an equivalent distribution kernel"_); Multipass
   Ubuntu 22.04→24.04 ships 5.15→6.8. Comfortably above the floor for kube-proxy
   replacement.
5. **No nested-virt dependency.** eBPF needs no nested virtualization — it's kernel
   in-VM. The macOS "nested virt" worry does not apply to eBPF specifically.

**Residual risks to actually test (don't take on faith):**
- Some minimal cloud kernels historically shipped BTF but gapped a specific
  `CONFIG_*` Cilium probes for; run `cilium status` / the Cilium preflight and read the
  agent log rather than assuming. A missing config surfaces as an agent CrashLoop, not a
  silent degrade.
- VXLAN tunnel over Multipass's DHCP bridge is the conservative choice; native routing
  would need the host bridge to carry pod routes, which Multipass does not guarantee.
- Per-VM weight: Cilium agent + operator + Hubble on 2-vCPU/2G lab VMs is real overhead;
  size workers up (mirror how `enable_coroot` auto-bumps the k0s VM to 4 vCPU / 8G).

## Hubble

Hubble is Cilium's eBPF flow-observability layer (L3–L7 service map, per-flow
visibility, DNS/HTTP metrics) with a UI (`cilium hubble enable && cilium hubble ui`).

**What it adds vs the existing Fluent-Bit/otelcol → OpenObserve pipeline:** the current
pipeline ships **logs**; Hubble surfaces **network flows and connectivity** — who talked
to whom, drops/denials, service dependency map, L7 (HTTP/DNS) request visibility — which
logs don't capture. It overlaps more with the existing **Coroot eBPF** stack
(`enable_coroot`) than with the log pipeline; both are eBPF network observability, so
running both is redundant for a lab.

**Worth it for this lab?** Marginal. It's a genuinely nice teaching artifact for "see the
service mesh without a mesh," but it duplicates Coroot's niche and costs resources. Treat
Hubble as a **sub-toggle of `enable_cilium`** (default off even when Cilium is on), not a
reason to adopt Cilium on its own.

## podCIDR / serviceCIDR + Multipass subnet-collision

- **k0s defaults** (per docs): `podCIDR: 10.244.0.0/16`, `serviceCIDR: 10.96.0.0/12`,
  per-node mask `/24` (256 pod IPs/node). These match what `centralized_logging` already
  runs and what the prior Proxmox brief pins — keep them for consistency.
- **Collision check:** Multipass on macOS hands out guest IPs from its own bridge, most
  commonly the **`192.168.64.0/24`** range (the `bridge100`/`mpqemubr0` network). That
  does **not** overlap `10.244/16` (pods) or `10.96/12` (services), so the k0s defaults
  are safe on Multipass out of the box. **Verify per-machine** (`ifconfig bridge100` /
  the Multipass network) since a user could have reconfigured it into 10.x — if so,
  re-base podCIDR/serviceCIDR off 10.x. This applies identically to kube-router and
  Cilium.
- Dual-stack is available on both providers (kube-router native; Cilium needs its own v6
  config) but is **out of scope** for the lab — leave `dualStack.enabled` off.

## Recommendation (incl. `enable_cilium` flag y/n)

**Default CNI for the lab: `kuberouter`. `enable_cilium` flag: YES — but for iteration 2,
defaulting OFF.**

Crisp tradeoff:

> kube-router gets a working 6-node HA cluster with zero extra moving parts and matches
> the repo's existing single-node k0s exactly — lowest risk to stand the cluster up.
> Cilium buys eBPF kube-proxy-replacement + Hubble flow visibility (a better story for a
> "prototype-before-Proxmox" lab) at the cost of a Helm step, a hard dependency on the
> CPLB VIP being reachable at install time, heavier VMs, and a harder debug surface. Since
> CNI is immutable post-init, you cannot A/B it in place — so build v1 on kube-router,
> land HA + backups first, then offer Cilium as a **rebuild-only** opt-in
> (`enable_cilium=true` → `just recreate centralized_k0s`), never a live mutate.

Flag mechanics (follow the repo's `enable_coroot`/`dns_server` idioms):
- `enable_cilium` (bool, default `false`) — templates `provider: custom` +
  `kubeProxy.disabled: true` into the k0s config and adds the Helm install to cloud-init.
  Because it lives in cloud-init/cluster-init, enabling it needs `just recreate`, not
  `just up` (same note the repo already makes for cloud-init edits and `enable_coroot`).
- `enable_hubble` (bool, default `false`) — sub-toggle, only meaningful when
  `enable_cilium=true`.
- Cilium's `k8sServiceHost` **must** be wired to the HA shard's CPLB VIP — coordinate the
  variable so the two shards agree on the VIP value.
- Hermetic tests must assert **both** off by default (mirror the repo's
  `*_off_by_default` tftest pattern) and that setting `enable_cilium` renders
  `provider: custom` + `kubeProxy.disabled: true`.

## Open risks / adversarial-bait

- **"Just use Cilium, it's the modern choice."** For a lab whose stated job is
  prototype-before-Proxmox, correctness of the HA control plane matters more than CNI
  sophistication. Cilium's kube-proxy-replacement failure mode (unreachable
  `k8sServiceHost` at boot → cluster networking never converges, silent hang) is exactly
  the DNS-race / silent-wait-loop class this repo has been repeatedly bitten by. Don't
  couple the first HA bring-up to it.
- **CPLB VIP coupling is a real cross-shard dependency.** If the HA shard chooses external
  HAProxy instead of CPLB, `k8sServiceHost` points at the HAProxy IP, not a VIP — the
  Cilium value is only decidable once the HA shard lands. This is a reason to defer Cilium
  to iteration 2, not merely a preference.
- **BTF/config assumption unverified until a VM exists.** The eBPF-feasibility argument is
  sound but must be confirmed on an actual Multipass arm64 VM (`ls /sys/kernel/btf/vmlinux`,
  `cilium status`) before trusting it — I did not launch a VM to prove it. Treat feasibility
  as high-probability, not proven.
- **Hubble ↔ Coroot redundancy.** Enabling both eBPF observability stacks on small VMs is
  wasteful; if Cilium+Hubble lands, reconsider whether `enable_coroot` should co-exist.
- **Multipass subnet is host-specific.** The 192.168.64/24 assumption holds for stock
  Multipass but is not guaranteed; a user who re-based the Multipass network into 10.x
  would collide with the k0s defaults — verify, don't assume.
- **One blog was inaccessible.** The `aws.plainenglish.io` / Medium "GitOps journey" post
  is behind a login/redirect wall (307 loop to `medium.com/m/global-identity`); its
  homelab lessons could not be extracted. Findings here lean on the oneuptime k0s+Cilium
  guide (fully fetched) + the k0s official docs + the prior Proxmox brief.

## Sources

- k0s networking (provider selection, kube-router default, custom opt-out, immutability):
  https://docs.k0sproject.io/stable/networking/
- k0s runtime (containerd/runc default; no explicit eBPF kernel reqs stated):
  https://docs.k0sproject.io/stable/runtime/
- k0s feature gates (`--feature-gates` syntax; only `IPv6SingleStack` documented):
  https://docs.k0sproject.io/stable/feature-gates/
- k0s dual-stack (podCIDR/serviceCIDR defaults `10.244.0.0/16` / `10.96.0.0/12`,
  `/24` node mask, per-provider dual-stack behavior):
  https://docs.k0sproject.io/stable/dual-stack/
- oneuptime — Cilium on k0s (custom provider, kubeProxy.disabled, Helm
  kubeProxyReplacement, `k8sServiceHost`≠127.0.0.1, kernel 5.10+, Hubble):
  https://oneuptime.com/blog/post/2026-03-13-configure-cilium-k0s/view
- aws.plainenglish.io "k0s on a home server: a GitOps journey" — **inaccessible**
  (Medium login/redirect wall): https://aws.plainenglish.io/k0s-on-a-home-server-a-gitops-journey-9426054b230f
- Prior Proxmox brief (Cilium section, immutability caveat, CPLB VIP):
  `ai_docs/claude-multipass-infra-upgrade-brief.md`
- Repo current state: `clusters/centralized_logging/cloud-init/k0s-client.yaml.tftpl`
  (`k0s install controller --single`, no network override → default kube-router).
