# Spec: centralized_k0s Cluster

> **Status: IMPLEMENTED and verified.** Synthesized from a 5-agent research fleet
> (`specs/centralized_k0s/*.md`), refined through user review (Vector, k0sctl, `--enable-worker`,
> smaller default, native HAProxy exporter), then **hardened against three hostile reviewers** whose
> confirmed findings are folded in below (see § "Adversarial fixes applied"). The build is now green
> from source: `just check` **9/9**, `just verify` **26 passed / 25 skipped / 0 failed** (skips are
> the expected HA-only roles/tests), no live patches. Implementation lives in
> [`clusters/centralized_k0s/`](../clusters/centralized_k0s/) (flags:
> [`docs/feature-flags.md`](../clusters/centralized_k0s/docs/feature-flags.md)); the backing build
> plans are [`build-plans/core.md`](centralized_k0s/build-plans/core.md),
> [`build-plans/k0sctl.md`](centralized_k0s/build-plans/k0sctl.md),
> [`build-plans/node.md`](centralized_k0s/build-plans/node.md), and
> [`build-plans/vector-tests.md`](centralized_k0s/build-plans/vector-tests.md). Where this umbrella
> disagrees with a backing shard, **the umbrella wins** (shards predate the review — their stale
> datastore/version claims are superseded here).

## Context

The `centralized_monitoring` cluster carries a **single-node** k0s VM (`k0s install controller
--single`, kine/SQLite, kube-router, unpinned `get.k0s.sh`) that doubles as a monitored node;
`centralized_logging` runs the same shape for Coroot. This cluster **extracts k0s into its own
`clusters/centralized_k0s/`** and levels it up to a multi-node etcd cluster — first on **Multipass**
(arm64-Mac stand-in), then **Proxmox**. The prior `ai_docs/claude-multipass-infra-upgrade-brief.md`
is Proxmox-oriented; this refines it for Multipass. **k0s stays in `centralized_monitoring` untouched
until `just verify centralized_k0s` is green.**

## Objective

A `just`-orchestrated k0s cluster mirroring every repo convention, providing:

- **Tunable topology** — default **1 controller + 2 workers** (fits `up-connected`); **3 controllers
  + 3 workers + HAProxy** as an HA opt-in; **etcd unconditionally** (single-member in default mode),
  **no SELinux**.
- **etcd-quorum HA behind an HAProxy edge** (opt-in) — *not* full HA (the single HAProxy is a
  deliberate lab SPOF; full CPLB+NLLB HA is the Proxmox target). HAProxy is **conditional** on >1
  controller and exposes its **native Prometheus exporter** on `:8405`.
- **k9s, stern, helm, kubectl, etcdctl** on every node; **admin kubeconfig distributed to all nodes**.
- **kubelet + cAdvisor on controllers** (via `--enable-worker`, control-plane taint kept) + the full
  exporter set + **Netdata**, role-aware.
- **All logs → `centralized_logging`** via **Vector** — host/k0s-component as syslog; pod logs parsed
  from the `/var/log/pods` path (namespace/pod/container, **no K8s API dependency**) → structured to
  the monitoring hub's OpenObserve + a flat syslog archival copy to logging.
- **oh-my-zsh** + zsh completions (`etcd, kubectl, helm, stern, k9s, k0s`) on all nodes.
- **Cilium** as an opt-in CNI (`enable_cilium`, iteration 2).
- **Cluster formation by k0sctl** now; **Ansible** (`ansible-dev` plugin) migrates node config later.

## Architecture

### Topology & resource sizing

Node counts are `count`-driven vars; the control-plane count decides HA *and* whether HAProxy exists.
**Datastore is `etcd` in both modes** (single-member when 1 controller — keeps the 1↔3 render and the
hermetic assertion coherent; the shards' "kine/SQLite" claim is superseded).

| Mode | controllers | workers | HAProxy | VMs | ~vCPU / RAM | etcd |
|---|---|---|---|---|---|---|
| **Default** (`up-connected`-fit) | 1 | 2 | ❌ (direct to controller-1) | 3 | ~6 / 8–10 G | single-member |
| **HA opt-in** (`k0s_control_plane_count=3`) | 3 | 3 | ✅ | 7 | ~13 / 19 G | 3-member quorum |

Per-VM sizing (tunable `object({cpus,memory,disk})` vars): controller **3 vCPU / 3 G / 20 G** (etcd
+ control plane + kubelet/cAdvisor via `--enable-worker`; 3 G for etcd OOM headroom, cf.
`specs/centralized-logging-k0s-perf.md`), worker **2 vCPU / 4 G / 30 G**, haproxy **1 vCPU / 1 G /
10 G** (only when controllers > 1). The **HA opt-in (~13 vCPU / 19 G) is essentially the whole Mac —
bring it up stand-alone**; `up-connected` uses the 3-VM default.

### Provider & runtime-IP injection

VMs are `count`-indexed and 1-named: `centralized-k0s-controller-1..N`, `-worker-1..M`, `-haproxy`.
**Correction (adversarial):** `count` instances create in *parallel* — there is no "controller[0]
anchor." The real create-before-render edge is that the rendered `k0sctl.yaml`/`local_file`s
reference **`multipass_instance.controller[*].ipv4`** (all of them), forcing every VM created before
render and before the post-apply bootstrap. Providers pin as elsewhere (`larstobi/multipass ~> 1.4`,
`hashicorp/local ~> 2.4`, `required_version >= 1.7`).

**`hosts` output** — dynamic `{role:{name,ipv4}}`; HAProxy conditional (count-gated, like
`centralized_netbox`'s `agent[0]`):
```hcl
output "hosts" {
  value = merge(
    { for i, c in multipass_instance.controller : "controller-${i + 1}" => { name = c.name, ipv4 = c.ipv4 } },
    { for i, w in multipass_instance.worker     : "worker-${i + 1}"     => { name = w.name, ipv4 = w.ipv4 } },
    var.k0s_control_plane_count > 1 ? { haproxy = { name = multipass_instance.haproxy[0].name, ipv4 = multipass_instance.haproxy[0].ipv4 } } : {},
  )
}
```
Also export `k0s_api_endpoint` and `dns_records` (see next). **Stable endpoint (backup/restore
footgun fix):** register `k0s-api.<domain>` in `dns_records` → the HAProxy IP (or controller-1 in
single mode), and set `spec.api.externalAddress` to that **hostname**, not the churning DHCP IP — so
`k0s backup`/`restore` (which requires `externalAddress` unchanged) survives a rebuild.

### Control-plane HA + load balancer (HAProxy, conditional)

When `k0s_control_plane_count > 1`, an HAProxy VM fronts the controllers; `spec.api.externalAddress`
= `k0s-api.<domain>` (resolving to the HAProxy IP), added to every controller's `spec.api.sans`. It
passes three TCP ports (L4 passthrough): **6443** (apiserver), **8132** (konnectivity), **9443**
(controller join). Single-controller mode sets `externalAddress` = `k0s-api.<domain>` → controller-1,
no HAProxy.

**Native Prometheus metrics** (no sidecar), scraped by the monitoring hub at `haproxy:8405/metrics`:
```haproxy
frontend prometheus
  bind :8405
  mode http
  http-request use-service prometheus-exporter if { path /metrics }
  no log
# + mode tcp frontends/backends on 6443/8132/9443 → the controllers (option tcp-check)
```

**HA honesty (adversarial reframe).** This is **etcd-quorum HA behind a SPOF edge**, not full HA:
`externalAddress` + a single HAProxy **disables NLLB** and routes every worker→API through one VM on
one Mac. The failover drill (kill a controller) validates **etcd quorum (2/3) + HAProxy backend
health-checking** — killing the HAProxy VM drops the whole control plane. Full CPLB+NLLB HA is the
Proxmox target (a config edit, not a rebuild). **Why not CPLB on Multipass:** VRRP needs a free
in-subnet VIP the dnsmasq won't lease + multicast/GARP over `vmnet` — unverified/risky. **roxy-wi**
(management UI) is deferred — x86_64-only, needs its own server+DB+agents. Details:
`specs/centralized_k0s/ha-loadbalancer.md`.

### Cluster bootstrap & join — k0sctl

**Decision: k0sctl.** Cloud-init does **only** OS prep — DNS warm-up gate + retryable pinned
`get.k0s.sh` install + CA trust + tooling + Vector/exporters — and **runs no `k0s install`/`k0s
start` and NO API-dependent step**. A post-apply `terraform_data.k0s_bootstrap` (mirroring
`centralized_monitoring`'s `terraform_data.k0s_log_shipper`) renders **one** `k0sctl.yaml` and runs
`k0sctl apply`; k0sctl distributes PKI automatically and enforces controller→controller→worker order.

**Adversarial hardening baked in:**
- **No API-dependent steps in cloud-init.** Copying the existing single-node templates would drag in
  `until … k0s kubectl /readyz; do sleep 5; done` (KSM, ingress, `k0s kubeconfig admin`) that run
  against a cluster that does not exist until k0sctl runs → the canonical **infinite cloud-init hang**
  (`multipass launch` never returns). **kube-state-metrics and any manifest are applied post-apply**
  via the **k0s manifest deployer** (`/var/lib/k0s/manifests/<stack>/`, laid down by k0sctl config
  `spec.k0s.config` or a `terraform_data` after bootstrap) — never in cloud-init.
- **One shared cluster config, not per-controller `k0s.yaml`.** k0sctl takes a single
  `spec.k0s.config` and derives per-node `api.address`/etcd `peerAddress` from each host. Node-role
  differences (controllers get `--enable-worker`) are **per-host `installFlags`**, not config fields.
  So there is **no per-controller `k0s.yaml` artifact** — hermetic tests assert on the rendered
  `k0sctl.yaml`.
- **Pin `privateAddress` explicitly.** Set `spec.hosts[*].privateAddress` = the tofu-discovered
  `ipv4` for every host — do **not** rely on k0sctl fact-gathering (it can pick a CNI bridge
  `10.244.x` interface → apiserver-SAN / etcd-peer IP mismatch → silent TLS/quorum failure).
- **Ordering.** `terraform_data.k0s_kubeconfig_distribute` and the KSM-manifest step
  **`depends_on = [terraform_data.k0s_bootstrap]`** so they never run before the cluster exists.
- **k0sctl preflight (real, not aspirational).** Add a `command -v k0sctl` gate to the `just up`
  recipe (there is **no** existing tool-preflight in the Justfile) that fails with
  "install k0sctl: brew install k0sproject/tap/k0sctl", AND make the `terraform_data` fail-fast with
  the same message — otherwise a missing k0sctl fails `apply` mid-flight (VMs created), and
  `up-connected`'s consumer loop swallows the `rc=1` and reports a "green" fleet with a broken node.

**Version pin.** `var.k0s_version` default **`v1.34.9+k0s.0`** (Kubernetes 1.34.9, **etcd 3.6.12** —
confirmed real); threaded into `K0S_VERSION` + `k0sctl.yaml` `spec.k0s.version`. `kubectl` = k8s
minor, `etcdctl` = **3.6.x** (the tooling shard's `etcdctl v3.5.21` is stale — superseded). Verify all
three against `k0s version` in the Phase-0 spike. etcd 3.5→3.6 "zombie member" hop only bites a future
in-place 1.33→1.34 upgrade.

**Boot-race hardening — every network fetch, not just k0s.** `runcmd` is `/bin/sh` (no `set -e`), so
a first-boot DNS-warm-up miss on *any* download fails silently. Make the resolver warm-up gate
**unconditional** (not only under `dns_server != ""`) and wrap **every** network install — `get.k0s.sh`,
oh-my-zsh (`raw.githubusercontent.com`), Vector, `install-cli.sh` GitHub releases (kubectl/helm/k9s/
stern/etcdctl), netdata — in the bounded-retry idiom, warming the actual hosts hit:
```yaml
  - systemctl restart systemd-resolved
  - |
    for h in get.k0s.sh github.com raw.githubusercontent.com get.helm.sh; do
      for i in $(seq 1 30); do getent hosts "$h" >/dev/null 2>&1 && break; sleep 2; done
    done
  - |
    for i in $(seq 1 5); do curl -sSLf https://get.k0s.sh | K0S_VERSION=${k0s_version} sh && break; sleep 5; done
```
**300s launch window:** 7 concurrent `multipass launch`es each doing `package_upgrade` + 6 downloads
+ netdata will contend and can exceed Multipass's 300s window → timeout → orphaned VM → next `up`
collides (`just prune` recovery). Mitigate: `package_upgrade: false` and move heavy tool/Vector/
netdata installs into a **post-boot systemd oneshot** (`--no-block`, the netbox `netbox-stack.service`
pattern) so cloud-init reaches `done` fast; document the `prune`/`recreate` recovery.

### CNI / networking

**v1 default `kuberouter`**; **`enable_cilium` opt-in iteration 2** (`provider: custom` +
`kubeProxy.disabled: true` + Helm with `kubeProxyReplacement=true`, `k8sServiceHost=k0s-api.<domain>`).
eBPF on Multipass arm64 is feasible but unproven; CNI is immutable post-init → `enable_cilium` is a
`just recreate`-class flag. Keep k0s defaults `podCIDR 10.244.0.0/16` / `serviceCIDR 10.96.0.0/12`
(no collision with Multipass's `192.168.64.0/24` — verify per-machine).

### Node tooling & shell UX

`install-cli.sh` (arch-substituted release → `/usr/local/bin`), **unconditional** on every node:
kubectl (`v1.34.x`, real binary), helm `v3.21.2` (make unconditional), k9s `v0.51.0`, stern
`v1.34.0` (`--completion=zsh`), etcdctl (3.6.x). **kubeconfig on all nodes:** controllers
self-generate; `terraform_data.k0s_kubeconfig_distribute` (after bootstrap) pulls the admin config
(its `server:` already = `k0s-api.<domain>`) and scps to `/home/ubuntu/.kube/config` on every node.
**oh-my-zsh** unattended as `ubuntu` (`RUNZSH=no CHSH=no KEEP_ZSHRC=yes`), `chsh zsh`, one
`~/.oh-my-zsh/completions/_<tool>` per tool — installed in the post-boot oneshot, after the resolver gate.

### Observability — exporters + Netdata

Controllers run kubelet + cAdvisor (via `--enable-worker`, taint kept → metrics + pod logs, no user
pods). Host exporters everywhere; kube-state-metrics once; etcd + k0s system metrics on controllers.

| Exporter | Port | Controllers | Workers | Notes |
|---|---|:---:|:---:|---|
| node/systemd/process | 9100/9558/9256 | ✅ | ✅ | v1.8.2 / v0.7.0 / v0.8.7 |
| Netdata | 19999 | ✅ | ✅ | scraped via **`netdata_scrape_targets`** (needs `metrics_path`+`params` — **not** `extra_scrape_targets`); `enable_netdata_ebpf` off (arm64) |
| kubelet RO / cAdvisor | 10255 / 8089 | ✅ (now) | ✅ | `--read-only-port`; cAdvisor v0.49.1 |
| kube-state-metrics | 8081 | — one cluster-wide Deployment (v2.13.0) — | | scheduled on a worker; **scrape-targeting caveat** below |
| etcd / k0s-pushgateway | 2381 / 9091 | ✅ | ❌ | pushgateway opt-in (`--enable-metrics-scraper`), 2-min TTL → scrape < 2 min |
| HAProxy | 8405 | — HAProxy VM (HA mode) — | | native exporter |

**KSM scrape-targeting caveat:** KSM (`replicas:1`, hostNetwork) lands non-deterministically on *one*
worker, but `extra_scrape_targets` is a static `{ip,port}` — you can't know the IP ahead of time.
Pin KSM to a specific worker (nodeSelector) or discover the landed node's IP post-apply and feed it
in. **Blackbox exporter is deferred** (see Future work) — it can't ride `extra_scrape_targets` and
needs a bespoke `centralized_monitoring` change (exporter container + `/probe` relabel job +
`insecure_skip_verify` for `:6443/readyz`).

### Log shipping to centralized_logging — Vector (no K8s API dependency)

**One Vector agent per node.** `centralized_logging` ingests only syslog RFC5424/TCP:514, so:

- **Host + k0s-component logs** — Vector `journald` source → **`socket` sink with
  `encoding.codec = "syslog"`** (RFC5424, TCP) → `centralized_logging:514`. (Vector has no "syslog
  sink" — it's the socket sink + syslog codec; explicitly populate `HOSTNAME`/`APP-NAME` fields so
  the hub's `keep-hostname(yes)` folders correctly.)
- **Pod logs (structured, no API) — path-parsed.** Vector **`file` source** on
  `/var/log/pods/*/*/*.log` (present on all nodes now that controllers run kubelet) → **VRL** parses
  the path `/var/log/pods/<ns>_<pod>_<uid>/<container>/` to extract **namespace / pod / container**
  (no Kubernetes API, no kubeconfig, no boot-order fragility — the `kubernetes_logs` source was
  rejected precisely because it needs API access Vector wouldn't have at boot) → two sinks:
  (a) the monitoring hub's **OpenObserve** — Vector **`http` sink** to `/api/<org>/<stream>/_json`
  with basic auth (`auth.user`/`auth.password`), `encoding.codec=json`, **`buffer.when_full =
  drop_newest`** (so a down hub can't back-pressure and stall the archival path), and
  (b) a flat **socket/syslog** archival copy to `centralized_logging`.
  *Loses only pod labels/annotations* (not ns/pod/container) — acceptable for the lab.
- **Var plumbing:** `log_shipping_target` (→ logging syslog) + `openobserve_endpoint`/`_org`/
  `_password` **+ a new `openobserve_stream` value** (the `_json` URL names the stream — not in the
  current cross-cluster var contract; add it). `up-connected` wires these from live hub IPs.

Config sketch lands under `cloud-init/vector/vector.toml.tftpl`. Multiline pod logs (stack traces):
ship intact to OpenObserve; the flat syslog copy may split at `\n` (archival only).

### No SELinux

N/A on Ubuntu (AppArmor); `apparmor_parser` (containerd's only need) is present. Note for a future
RHEL Proxmox guest.

## Layout

```
clusters/centralized_k0s/
├── main.tf                 # count controller/worker + conditional haproxy; k0sctl.yaml + cloud-init renders;
│                           #   terraform_data: k0s_bootstrap (k0sctl apply) → kubeconfig_distribute + ksm_manifest (depends_on bootstrap)
├── variables.tf            # k0s_control_plane_count(=1)/worker_count(=2), size objects, k0s_version,
│                           #   enable_cilium/enable_hubble, enable_netdata(+_ebpf), log_shipping_target,
│                           #   openobserve_endpoint/_org/_password/_stream, dns_server, internal_ca_cert, ntp_server
├── outputs.tf              # hosts{}, k0s_api_endpoint, dns_records (incl. k0s-api.<domain>), web_urls
├── cloud-init/
│   ├── controller.yaml.tftpl / worker.yaml.tftpl   # OS prep + DNS gate + pinned get.k0s.sh; heavy installs in a post-boot oneshot; NO k0s install / NO API-dependent step
│   ├── haproxy.yaml.tftpl                           # L4 cfg + :8405 prometheus frontend
│   ├── k0sctl.yaml.tftpl                            # ONE cluster config; per-host privateAddress + installFlags(--enable-worker on controllers)
│   └── vector/vector.toml.tftpl                     # journald→socket/syslog + file(/var/log/pods)→VRL→OpenObserve(http)+syslog copy
├── tests/{tofu/sizing_and_render.tftest.hcl, testinfra/conftest.py + test_*.py}
└── docs/feature-flags.md
```

## Testing — layered feedback loop

Pin cross-cluster opt-ins **OFF** in each test file's file-level `variables {}` — the full list:
`dns_server, internal_ca_cert, ntp_server, enable_cilium, log_shipping_target, openobserve_endpoint,
openobserve_stream` (a stale `.cross-cluster.auto.tfvars.json` will otherwise poison `just check`).

- **Hermetic** (`mock_provider`, `command = plan`, `strcontains`/`yamldecode` — `just check`): default
  renders 1 controller + 2 workers, **no HAProxy**; a `k0s_control_plane_count=3` run renders 3+3
  **+HAProxy** (controller 3 vCPU/3 G) with the `:8405` frontend; the rendered **`k0sctl.yaml`**
  (not per-controller files) carries `storage.type: etcd` in **both** modes, per-host `privateAddress`,
  `installFlags` with `--enable-worker` on controllers, and `externalAddress: k0s-api.<domain>`; every
  node's cloud-init has the pinned tool installs + `K0S_VERSION`, the **unconditional** resolver gate,
  oh-my-zsh + `_<tool>` completions, and the **Vector** config (journald→syslog + `file`
  /var/log/pods→OpenObserve `http` sink); `k0s_bootstrap` + `kubeconfig_distribute`(`depends_on`) exist;
  `_off_by_default` for `enable_cilium`/`log_shipping_target`/`openobserve_endpoint`.
- **Live** (`tests/testinfra/` over SSH — `just verify`): each controller `sudo k0s status` Running;
  `sudo k0s kubectl get nodes` all Ready (3 default / 6 HA); HA mode `k0s etcd member-list` = 3 +
  failover drill; standalone `kubectl get nodes` as `ubuntu` on every node; tools present; zsh +
  completions; Vector running + **enrichment asserted** (an OpenObserve record with populated
  `namespace/pod/container`, not just "a record appears") + syslog line in `/var/log/remote/`;
  HAProxy `:8405/metrics` returns `haproxy_*` (HA). **Fixtures:** the "dynamic per-role" idea isn't a
  real pytest pattern — enumerate the **max** role set as **skip-guarded** fixtures (the netbox
  `agent` idiom: `controller-2`, `controller-3`, `worker-3`, `haproxy` each `pytest.skip` when absent),
  or `@pytest.mark.parametrize` over `hosts.keys()`.

## Quickstart

```sh
just check   centralized_k0s
just up      centralized_k0s          # default 1+2; preflight checks k0sctl; k0sctl forms the cluster
K0S_HA=1 just up centralized_k0s      # 3+3+HAProxy, stand-alone
just verify  centralized_k0s
just recreate centralized_k0s         # after ANY cloud-init/k0sctl/vector edit
```
Preflight: `brew install k0sproject/tap/k0sctl`. Default 1+2 joins `up-connected`; 3+3 HA is stand-alone.

## Applying cloud-init / config changes

Edit cloud-init/`k0sctl.yaml`/`vector.toml` → **`just recreate`**, never `just up`. Iterate live via
SSH + `systemctl restart --no-block`, then fold back into the `.tftpl`.

## Decisions locked (review + adversarial rounds)

| Topic | Decision |
|---|---|
| Bootstrap | **k0sctl** (one shared config + per-host `installFlags`/`privateAddress`); Ansible later |
| Cloud-init | **OS prep only** — no `k0s install`, no API-dependent step (KSM/kubeconfig go post-apply) |
| Logs | **Vector**; pods via **`file`+path-parse** (no API) → OpenObserve `http` sink (`drop_newest`) + syslog copy; host→syslog |
| Controllers | `--enable-worker` + taint kept |
| Default size | **1 CP + 2 workers** (etcd single-member); **3+3+HAProxy** = HA opt-in, stand-alone |
| Datastore | **etcd unconditionally** (both modes) |
| HA framing | **etcd-quorum HA behind a SPOF edge** (lab), not full HA |
| HAProxy | conditional on >1 CP; native `:8405` exporter; endpoint via stable `k0s-api.<domain>` |
| Blackbox | **deferred** to a monitoring-hub change (future work) |
| roxy-wi | deferred to Proxmox (x86_64) |
| Version | `v1.34.9+k0s.0` / etcd 3.6.12 / etcdctl 3.6.x (verify in spike) |

## Adversarial fixes applied

The hostile reviewers' confirmed holes are addressed above: **no API-dependent steps in cloud-init**
(would hang); **single k0sctl config + `installFlags`** (per-controller `k0s.yaml` was dead);
**pinned `privateAddress`**; **`depends_on` ordering**; **Vector `file`+path-parse** (kills the
`kubernetes_logs` API/boot-order trap); **boot-race guard on all fetches + unconditional gate**;
**300s window → post-boot oneshot + `package_upgrade:false`**; **skip-guarded testinfra fixtures**;
**real k0sctl preflight**; **HA-honesty reframe**; **stable DNS endpoint** for backup/restore;
**Netdata via `netdata_scrape_targets`**; **blackbox deferred**.

**Residual risks accepted (lab):** HAProxy SPOF; pod-log labels/annotations dropped (ns/pod/container
kept); multiline pod logs split on the flat syslog archival copy; KSM scrape target needs the landed
worker IP.

## Future work

- **Blackbox exporter** as a `centralized_monitoring` enhancement (exporter container + `/probe`
  relabel job + `insecure_skip_verify` for `:6443/readyz`), asserted in that cluster's suite.
- **Ansible / `ansible-dev` plugin** migrates the node-config layer.
- **CPLB (Keepalived VIP) + NLLB** on Proxmox (real HA — a config edit, not a rebuild).
- **roxy-wi** HAProxy UI on x86_64 Proxmox. **Cilium + Hubble** (`enable_cilium`). **Storage/CSI**
  (OpenEBS/local-path; kubelet dir `/var/lib/k0s/kubelet`). **Backup/DR** (`k0s backup` + Velero).

## Sources

Backing research: `specs/centralized_k0s/*.md` (superseded where they disagree — stale kine/version
claims). Prior brief: `ai_docs/claude-multipass-infra-upgrade-brief.md`. Ansible:
`boss-skills/specs/ansible-dev-plugin.md`. Templates: `clusters/centralized_{logging,monitoring,netbox}/`.
k0s docs: `https://docs.k0sproject.io/stable/`.
