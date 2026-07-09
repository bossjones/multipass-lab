# centralized_k0s — shard: tooling, shell UX, kubeconfig, repo/test integration

> Research shard for the planned `clusters/centralized_k0s/` cluster: a **6-VM HA k0s cluster**
> (3 controllers + 3 workers) on Multipass, arm64 Mac standing in for future Proxmox. This
> document covers **node tooling**, **shell UX**, **kubeconfig distribution**, and **repo/test
> integration**. Other shards own the k0s topology/HA/etcd/CNI design and the final assembled spec.

## Summary

Every one of the 6 nodes should ship a **real `kubectl`** (not just `k0s kubectl`) plus the CLIs
already baked into `centralized_logging`'s single-node k0s VM — **k9s v0.51.0, stern v1.34.0, helm
v3.21.2** — and **`etcdctl`** (controllers run etcd). Installs reuse the cluster's existing
`install-cli.sh` idiom (download a GitHub release tarball or raw binary → `/usr/local/bin`), which
already does arm64 `{ARCH}` substitution. `kubectl` and `etcdctl` are new binaries; pin `kubectl` to
the **k0s Kubernetes minor** (k0s stable is ~`v1.34.x` → `kubectl v1.34.2`) and `etcdctl` to the
**etcd version k0s bundles** (~`v3.5.x`; verify with `k0s version` in the Phase-0 spike).

Controllers can mint their own admin kubeconfig (`k0s kubeconfig admin`); **workers cannot**. Set
`spec.api.externalAddress` (or the CPLB VIP) in `k0s.yaml` so the generated admin kubeconfig's
`server:` already points at the **LB VIP**, then fan that one kubeconfig out to all 6 nodes'
`/home/ubuntu/.kube/config` via a **post-apply `terraform_data` SSH/scp step** that mirrors the
existing `terraform_data.k0s_log_shipper` in `centralized_monitoring/main.tf`.

`oh-my-zsh` installs unattended in cloud-init on every node, `ubuntu`'s shell is switched to zsh,
and each tool's zsh completion (`k0s, kubectl, helm, stern, k9s, etcdctl`) is written into
`~/.oh-my-zsh/completions/` (which oh-my-zsh already puts on `fpath` before `compinit`).

Repo integration mirrors the runtime-IP-injection pattern: **controller-1 is created first** as the
IP anchor; node counts and sizes become tunable vars (`k0s_control_plane_count`/`k0s_worker_count`,
default 3+3; `controller`/`worker` size objects). **6 VMs at 2 vCPU each = 12 vCPU / ~18 GB is the
whole-Mac ceiling** — call it out and support shrinking to 1+2. Tests keep the repo's two-layer
split: hermetic `tofu test` asserts on 6-VM sizing / counts / rendered `k0s.yaml` (etcd) / tool
installs / kubeconfig placeholder + VIP; live testinfra asserts `k0s status`, `k0s kubectl get
nodes` = 6 Ready, tools present on all 6, `kubectl` usable by `ubuntu`, zsh + completions, log ship.

## Node tooling (all 6 nodes)

Reuse `install-cli.sh` (already in `centralized_logging/cloud-init/k0s-client.yaml.tftpl`, lines
98–115): it curls a release URL, untars if it's a tarball else treats it as a raw binary, and
`install -m0755`s the binary to `/usr/local/bin`. It already maps `dpkg --print-architecture`
(`aarch64→arm64`) into the `{ARCH}` placeholder, so the same URLs work on the Apple-Silicon lab and
on amd64 Proxmox. Add **kubectl** and **etcdctl** to the two CLIs it already installs.

| Tool | Version (pin) | Where | Install method (arm64 URL uses `{ARCH}`→`arm64`) |
|------|--------------|-------|--------------------------------------------------|
| **kubectl** | `v1.34.2` (match k0s k8s minor) | all 6 | raw binary: `install-cli.sh kubectl https://dl.k8s.io/release/v1.34.2/bin/linux/{ARCH}/kubectl kubectl` |
| **helm** | `v3.21.2` (carry) | all 6 | tarball: `install-cli.sh helm https://get.helm.sh/helm-v3.21.2-linux-{ARCH}.tar.gz helm` (make it **unconditional**; today helm only installs inside `coroot-install.sh`) |
| **k9s** | `v0.51.0` (carry) | all 6 | tarball: `install-cli.sh k9s https://github.com/derailed/k9s/releases/download/v0.51.0/k9s_Linux_{ARCH}.tar.gz k9s` |
| **stern** | `v1.34.0` (carry) | all 6 | tarball: `install-cli.sh stern https://github.com/stern/stern/releases/download/v1.34.0/stern_1.34.0_linux_{ARCH}.tar.gz stern` |
| **etcdctl** | `v3.5.21` (match bundled etcd — verify) | controllers (all 6 is fine, harmless) | tarball: `install-cli.sh etcdctl https://github.com/etcd-io/etcd/releases/download/v3.5.21/etcd-v3.5.21-linux-{ARCH}.tar.gz etcdctl` |
| **k0s** | `v1.34.2+k0s.0` (pin) | all 6 | `curl -sSLf https://get.k0s.sh \| K0S_VERSION=v1.34.2+k0s.0 sh` (pin the version rather than latest so `kubectl`/`etcdctl` minors stay in lockstep) |

Notes / adversarial bait:
- **Pin k0s explicitly.** `centralized_logging` runs `curl https://get.k0s.sh | sh` (latest). For a
  6-node cluster we must control the k8s minor so `kubectl v1.34.x` and the bundled etcd match; set
  `K0S_VERSION` env for the installer and expose it as `var.k0s_version`.
- **etcdctl version drift.** k0s ships its own etcd; a mismatched `etcdctl` still talks to it (v3 API
  is stable) but `etcdctl version` output will differ. Confirm the exact bundled etcd with
  `k0s version` / `k0s etcd member-list` during the spike and adjust the pin.
- **kubectl vs `k0s kubectl` skew.** A standalone `kubectl` one minor off the apiserver is supported
  by the k8s skew policy (±1). Keeping the pin equal to the k0s minor avoids surprises.
- Keep `install-cli.sh` **unconditional** for these (no `enable_*` gate) — they're the debug baseline,
  exactly as k9s/stern are unconditional in `centralized_logging` today.

## kubeconfig distribution (LB-VIP-pointed, all 6 nodes)

**Problem.** `k0s kubeconfig admin` works only on a **controller** (it reads the CA + issues an admin
client cert). Workers have no way to self-generate it, so `kubectl`/`k9s`/`stern` would be dead for
the `ubuntu` user on the 3 worker VMs. (This matches the brief's note: workers get no admin
kubeconfig by default; there is no standalone kubectl today, only `k0s kubectl`.)

**Make the server URL the VIP, at the source.** So the distributed kubeconfig is valid from any node
(and from the host), set the API external address to the **control-plane LB VIP** in `k0s.yaml`:

```yaml
spec:
  api:
    externalAddress: <VIP>       # k0s CPLB / keepalived VIP owned by the controllers
    sans: [ <VIP>, <controller-1 ip>, <controller-2 ip>, <controller-3 ip> ]
  network:
    controlPlaneLoadBalancing:
      enabled: true
      type: Keepalived           # VRRP VIP floats across the 3 controllers
```

With `externalAddress` set, `k0s kubeconfig admin` emits a kubeconfig whose `server:` is
`https://<VIP>:6443` automatically — no `sed` rewrite needed. (If CPLB is deemed too heavy for the
lab in the topology shard, fall back to `server: https://<controller-1 ip>:6443` and `sed`-rewrite
the localhost default; the distribution mechanism below is identical either way.)

**Distribution mechanism — mirror `terraform_data.k0s_log_shipper`.** `centralized_monitoring/main.tf`
already has the exact SSH-provisioner shape to copy (lines 386–408): a `terraform_data` with
`triggers_replace` on the relevant IPs/content and a `local-exec` that `ssh`/`scp`s onto the running
VM (SSH, **not** `multipass exec`/`transfer`, which don't route here — see CLAUDE.md). Adapt it:

1. Cloud-init on **every** node renders a **placeholder** `/home/ubuntu/.kube/config` (or leaves the
   dir empty) — the same "render a placeholder, push the real thing post-apply" idea the monitoring
   cluster uses for its otel config (`main.tf:32`).
2. Post-apply `terraform_data.k0s_kubeconfig_distribute` (`triggers_replace` = controller-1 ipv4 +
   the VIP + every worker ipv4):
   ```
   ssh -n <opts> ubuntu@<controller1_ip> 'cloud-init status --wait || true'
   ssh -n <opts> ubuntu@<controller1_ip> 'sudo k0s kubeconfig admin' > .rendered/admin.kubeconfig
   # (server: is already the VIP thanks to externalAddress; sed-rewrite here only if not)
   for ip in <all 6 node ips>; do
     scp <opts> .rendered/admin.kubeconfig ubuntu@$ip:/tmp/kubeconfig
     ssh -n <opts> ubuntu@$ip 'mkdir -p ~/.kube && cp /tmp/kubeconfig ~/.kube/config && chmod 600 ~/.kube/config'
   done
   ```
3. Controllers *also* drop their own via cloud-init (`k0s kubeconfig admin > /home/ubuntu/.kube/config`,
   exactly as `centralized_logging` does at lines 326–330) so they're usable before the post-apply
   step runs; the fan-out then overwrites them with the VIP-pointed copy for consistency.

This keeps the whole thing inside the repo's established patterns: runtime-IP-injected render +
post-apply SSH push, no new provider, no `multipass exec`.

## oh-my-zsh + completions (cloud-init recipe)

Install **non-interactively** on every node and generate one completion file per tool into
`~/.oh-my-zsh/completions/`. oh-my-zsh adds `$ZSH/completions` (= `~/.oh-my-zsh/completions`) to
`fpath` **before** it calls `compinit`, so dropping `_<tool>` files there is all that's needed — no
`.zshrc` edits, no `$ZSH_CUSTOM` plugin. (The k0s docs' Oh-My-Zsh recipe uses a `$ZSH_CUSTOM/plugins/k0s`
plugin + `$ZSH_CACHE_DIR/completions/_k0s`; the flat `~/.oh-my-zsh/completions/_k0s` form is simpler
and works identically for all six tools.)

Cloud-init shape (add `zsh` and `git` to `packages:`, then a runcmd block run **as the ubuntu user**
because oh-my-zsh installs under `$HOME`):

```yaml
packages: [ zsh, git, curl, tar ]     # plus the cluster's usual list

runcmd:
  # ... k0s install, tool installs (kubectl/helm/k9s/stern/etcdctl), kubeconfig drop ...

  # oh-my-zsh, unattended (RUNZSH=no keeps the installer from exec-ing a shell; CHSH=no so we
  # set the login shell ourselves below). Run as ubuntu so $HOME/.oh-my-zsh is owned correctly.
  - su - ubuntu -c 'RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"'

  # Generate each tool's zsh completion into oh-my-zsh's fpath dir (idempotent).
  - su - ubuntu -c 'mkdir -p ~/.oh-my-zsh/completions'
  - su - ubuntu -c '/usr/local/bin/k0s   completion zsh   > ~/.oh-my-zsh/completions/_k0s'
  - su - ubuntu -c '/usr/local/bin/kubectl completion zsh  > ~/.oh-my-zsh/completions/_kubectl'
  - su - ubuntu -c '/usr/local/bin/helm  completion zsh    > ~/.oh-my-zsh/completions/_helm'
  - su - ubuntu -c '/usr/local/bin/stern --completion=zsh  > ~/.oh-my-zsh/completions/_stern'
  - su - ubuntu -c '/usr/local/bin/k9s   completion zsh    > ~/.oh-my-zsh/completions/_k9s'
  - su - ubuntu -c '/usr/local/bin/etcdctl completion zsh  > ~/.oh-my-zsh/completions/_etcdctl'

  # Make zsh ubuntu's login shell (so `just ssh <cluster> <role>` lands in zsh with completions).
  - chsh -s /usr/bin/zsh ubuntu
```

Details / bait:
- `stern` uses `--completion=zsh` (a flag), **not** a `completion` subcommand — different from the
  Cobra tools. `k9s completion zsh`, `k0s completion zsh`, `kubectl completion zsh`, `helm completion
  zsh` are all subcommands.
- Completion files must be generated **after** the binaries are installed (order the runcmd
  accordingly). `etcdctl` completion only matters on controllers but is harmless everywhere.
- Ensure ownership: writing as `su - ubuntu -c` keeps `~/.oh-my-zsh` owned by ubuntu; a root-owned
  `~/.oh-my-zsh` would break `compinit` (or trip `compaudit`). If insecure-dir warnings appear, add
  `ZSH_DISABLE_COMPFIX=true` to `.zshrc` or `chown -R ubuntu:ubuntu ~/.oh-my-zsh`.
- k0s docs source for the completion commands + oh-my-zsh integration:
  <https://docs.k0sproject.io/stable/shell-completion/>.

## Repo integration & sizing (vars, hosts output, 6-VM budget)

**Runtime-IP injection for 6 VMs.** Follow the reference convention (CLAUDE.md → "Runtime IP
injection"): **`controller-1` is created first** and its computed `ipv4` is the anchor. Its IP feeds
(a) `k0s.yaml`'s `spec.api.sans`/`externalAddress`, and (b) every other node's cloud-init "join
address", forcing OpenTofu to create controller-1 before rendering the other five — exactly how
`centralized_logging` renders `client_conf` from `multipass_instance.central.ipv4` (`main.tf:123`)
and the docker VM references `multipass_instance.k0s.ipv4` (`main.tf:226`). Because k0s **join tokens
are minted at runtime** on controller-1 (they can't be known at render time), the actual join is a
**post-apply `terraform_data` SSH orchestration** (same mechanism as kubeconfig distribution): SSH to
controller-1, `k0s token create --role=controller` / `--role=worker`, scp each token to the matching
node, which runs `k0s install controller --token-file` / `k0s install worker --token-file`.

**Tunable node counts + sizes (new vars):**

```hcl
variable "k0s_control_plane_count" { type = number, default = 3 }   # odd for etcd quorum (1 or 3)
variable "k0s_worker_count"        { type = number, default = 3 }

variable "controller" {                       # object like centralized_netbox's `server`/`client`
  type    = object({ cpus = number, memory = string, disk = string })
  default = { cpus = 2, memory = "2G", disk = "20G" }
}
variable "worker" {
  type    = object({ cpus = number, memory = string, disk = string })
  default = { cpus = 2, memory = "4G", disk = "30G" }
}
```

Resources use `count`: `multipass_instance.controller[count.index]` /
`multipass_instance.worker[count.index]`, names `${var.name_prefix}-controller-${count.index + 1}`
and `-worker-${count.index + 1}` (hyphens; Multipass forbids underscores — folder is
`centralized_k0s`, VMs are `centralized-k0s-controller-1`, mapped via `replace(CLUSTER,"_","-")`).
Create `controller[0]` first (anchor); `controller[1..]` and all workers `depends_on` it (or simply
reference its `ipv4`, which creates the edge).

**`hosts` output map (6 roles), consumed by `tests/testinfra/conftest.py`:**

```hcl
output "hosts" {
  value = merge(
    { for i, c in multipass_instance.controller :
        "controller-${i + 1}" => { name = c.name, ipv4 = c.ipv4 } },
    { for i, w in multipass_instance.worker :
        "worker-${i + 1}" => { name = w.name, ipv4 = w.ipv4 } },
  )
}
```

(conftest builds SSH targets from `tofu output -json hosts` — a dynamic `{role:{name,ipv4}}` map, so
per-role fixtures should be generated from the keys rather than hard-coded like the 3-VM logging
conftest.) Also export `k0s_vip`, `k0s_version`, and (for `just open`) any dashboard `web_urls`.

**6-VM budget on ONE Mac — the real constraint.** Defaults sum to:

| Role | Count | Each | vCPU | RAM |
|------|-------|------|------|-----|
| controller | 3 | 2 vCPU / 2 G / 20 G | 6 | 6 G |
| worker | 3 | 2 vCPU / 4 G / 30 G | 6 | 12 G |
| **total** | **6** | | **12 vCPU** | **18 G** |

That is essentially the **entire** ~12-vCPU / ~18-GB budget the brief cites — there is **no
headroom** for the host, the other clusters, or `enable_coroot`-style add-ons. Ceiling call-outs:
- **12 vCPU / 18 G is the max.** Bringing this cluster up alongside any other running cluster will
  oversubscribe the Mac. `just up-connected` (which brings the whole fleet up) will not fit 6 more
  VMs — flag that this cluster is likely a **stand-alone bring-up**, or must shrink.
- **2 G controllers are tight.** Each controller runs etcd + apiserver + controller-manager +
  scheduler + kubelet. etcd under memory pressure is exactly the kind of thing that caused the global
  OOM documented in `specs/centralized-logging-k0s-perf.md`. Consider **2.5–3 G** controllers if the
  budget allows, or default to **1 controller** for laptops.
- **Laptop shrink:** `k0s_control_plane_count=1`, `k0s_worker_count=2` → 3 VMs, 6 vCPU / 8–10 G. A
  single controller disables etcd HA (kine/single-node etcd) but fits comfortably. Support this via
  the count vars; the hermetic test should cover a shrunk render (see below).

## Tests (hermetic + testinfra)

Keep the repo's **two-layer split** (`tests/tofu/*.tftest.hcl` hermetic with `mock_provider
"multipass" {}` + `command = plan` + `strcontains`; `tests/testinfra/` live over SSH). Pin the
cross-cluster opt-in vars (`dns_server`, `internal_ca_cert`, `ntp_server`) OFF in each test file's
`variables {}` block, per the auto-tfvars gotcha in CLAUDE.md.

**Hermetic (`tofu test`) — assert without launching VMs:**
- **6-VM sizing/counts:** with defaults, `length(multipass_instance.controller) == 3` and
  `length(multipass_instance.worker) == 3`; controller[0] cpus/mem/disk == 2/2G/20G; worker[0] ==
  2/4G/30G; names carry the `name_prefix` and are 1-indexed (`centralized-k0s-controller-1`,
  `-worker-1`).
- **Shrink render:** a run with `k0s_control_plane_count=1, k0s_worker_count=2` yields exactly 3
  instances total (guards the count wiring + laptop mode).
- **Rendered `k0s.yaml` carries etcd / HA:** `strcontains` the controller cloud-init for the etcd
  storage type (default etcd, not kine), `controlPlaneLoadBalancing`, `externalAddress`/`sans` with
  the (mock) VIP, and the join-address anchor referencing controller-1.
- **Tool installs on every node's cloud-init:** markers `kubectl` (`dl.k8s.io/release/v1.34.2`),
  `helm-v3.21.2`, `derailed/k9s` + `v0.51.0`, `stern/stern` + `stern_1.34.0`, `etcd-io/etcd` +
  `v3.5.21`, and `K0S_VERSION=v1.34.2+k0s.0`.
- **zsh + completions:** cloud-init contains `zsh` in packages, the unattended `ohmyzsh` install line,
  `~/.oh-my-zsh/completions/_kubectl` (+ `_k0s/_helm/_stern/_k9s/_etcdctl`), and `chsh -s
  /usr/bin/zsh ubuntu`.
- **kubeconfig distribution wiring:** every node renders the `/home/ubuntu/.kube/config` placeholder;
  the `terraform_data.k0s_kubeconfig_distribute` provisioner exists and its command references the
  VIP as `server` (or a `sed` rewrite of it) — assert via a rendered-content / plan check.
- **YAML validity:** `can(yamldecode(...))` on each rendered cloud-init after all the splices (the
  logging suite does this for every VM — mirror it for controllers + workers).

**Live (`tests/testinfra/`) — over SSH against running VMs:**
- **Cluster health:** on each controller, `sudo k0s status` is `Running` (role controller); on each
  worker `sudo k0s status` shows a worker. `sudo k0s kubectl get nodes` on a controller shows **6
  Ready** nodes (never bare `kubectl get nodes` for the *health* assertion — mirror the logging suite,
  which uses `sudo k0s kubectl`).
- **Standalone kubectl works for `ubuntu`:** on **every** node (incl. all 3 workers), `kubectl get
  nodes` (as `ubuntu`, using the distributed `~/.kube/config`) returns 6 nodes — this is the
  worker-kubeconfig-distribution proof, distinct from the `k0s kubectl` health check above.
- **Tools present on all 6:** `kubectl version --client`, `helm version`, `k9s version`, `stern
  --version`, `etcdctl version` all exit 0.
- **Shell UX:** `getent passwd ubuntu` ends in `/usr/bin/zsh`; `~/.oh-my-zsh` exists and is
  ubuntu-owned; each `~/.oh-my-zsh/completions/_<tool>` file exists and is non-empty (or a
  non-interactive `zsh -ic 'compinit; ...'` smoke that a completion is registered).
- **etcd HA:** on a controller, `sudo k0s etcd member-list` (or `etcdctl` against the k0s etcd)
  reports 3 members.
- **Logs shipping** (if this cluster opts into `log_shipping_target`): the shared syslog-ng client
  drop-in is present and active — reuse the logging cluster's shipping assertions.
- Parametrize per-role fixtures from the `hosts` output keys (dynamic — 6 roles, or 3 when shrunk),
  so the suite adapts to the count vars instead of hard-coding fixtures like the 3-VM logging conftest.

## Open risks / adversarial-bait

- **join tokens are runtime-only.** Unlike `dns_server`/`internal_ca_cert` (pure render-time
  splices), a multi-node k0s cluster *cannot* be brought up by cloud-init alone — controller/worker
  join needs tokens minted on controller-1 after it boots. The design leans on a **post-apply
  `terraform_data` SSH orchestration** (join + kubeconfig fan-out). If a reviewer expects a
  fully-declarative `just up`, note that this is an inherent k0s-HA constraint; k0sctl is the
  alternative but breaks the repo's cloud-init+tofu pattern. Editing this orchestration/cloud-init
  means `just recreate`, not `just up`.
- **2 G controllers may OOM.** etcd + control-plane on 2 G is aggressive; watch for the global-OOM
  failure mode from `specs/centralized-logging-k0s-perf.md`. Prefer 3 G controllers or 1 controller
  on a laptop.
- **Whole-Mac budget.** 12 vCPU / 18 G leaves nothing for the host or other clusters — this cluster
  probably can't join `just up-connected` at full size. Make counts/sizes prominent tunables.
- **CPLB/keepalived on Multipass.** A floating VRRP VIP across 3 controllers on Multipass's bridged
  network may or may not work cleanly (multicast/L2 behavior). The topology shard owns this; the
  kubeconfig-distribution design degrades gracefully to `server: https://<controller-1 ip>:6443` +
  `sed` if CPLB is dropped.
- **kubectl/etcdctl version drift.** Pin `kubectl` to the k0s k8s minor and `etcdctl` to the bundled
  etcd; **verify both against `k0s version`** in the Phase-0 spike rather than trusting the pins here
  (k0s stable moves; `v1.34.2+k0s.0` / etcd `v3.5.21` are best-effort estimates at authoring time).
- **DNS warm-up race.** With `dns_server` set, the k0s installer curl can lose the resolver race
  (`Could not resolve host: get.k0s.sh`) and silently loop — carry the `getent hosts` resolver gate +
  installer retry loop that `centralized_logging/cloud-init/k0s-client.yaml.tftpl` already uses
  (lines 293–316) into every controller/worker template.
- **oh-my-zsh install reaches the internet** at boot (raw.githubusercontent.com) — same network-race
  exposure; consider vendoring or a retry, and it must sit **after** the resolver gate.
- **helm currently conditional.** In `centralized_logging` helm only installs inside
  `coroot-install.sh` (gated on `enable_coroot`). For this cluster helm must be **unconditional** on
  every node — don't inherit the gated install.

## Sources

- k0s shell completion — <https://docs.k0sproject.io/stable/shell-completion/> (zsh completion for
  k0s; oh-my-zsh via `$ZSH_CUSTOM` plugin or flat `~/.oh-my-zsh/completions/`; `fpath` before
  `compinit`).
- k0s CLI reference — <https://docs.k0sproject.io/stable/cli/> (`k0s kubeconfig`, `k0s kubectl`,
  `k0s status`, `k0s completion`, `k0s token`, `k0s install controller/worker`).
- k0s user management — <https://docs.k0sproject.io/stable/user-management/> (`k0s kubeconfig
  create`/`admin`, `--groups system:masters`, redirect to file for distribution; long-lived
  non-revocable client certs).
- k0s upgrade — <https://docs.k0sproject.io/stable/upgrade/> (single-binary replace; k0sctl
  `spec.k0s.version`; controllers one-at-a-time, workers in 10% drained batches; explicit version
  `vX.Y.Z+k0s.0`).
- k0s backup/restore — <https://docs.k0sproject.io/stable/backup/> (`k0s backup --save-path` /
  `k0s restore`; captures `<data-dir>/pki` + etcd snapshot + k0s.yaml + manifests; **must run on a
  controller**; HA restore = fresh controller then rejoin).
- `clusters/centralized_logging/cloud-init/k0s-client.yaml.tftpl` — `install-cli.sh`/`install-exporter.sh`
  idiom, k9s v0.51.0 + stern v1.34.0 installs, helm v3.21.2 (in `coroot-install.sh`), admin
  kubeconfig drop for `ubuntu`, DNS-race gate + installer retry, `k0s install controller --single`.
- `clusters/centralized_logging/main.tf` — runtime-IP-injection edge (`client_conf` from
  `central.ipv4`), `local.k0s_size` auto-bump pattern, per-VM render → `local_file`.
- `clusters/centralized_monitoring/main.tf:386-408` — `terraform_data.k0s_log_shipper` post-apply
  SSH/scp provisioner (the template for kubeconfig distribution + join orchestration); `ssh_opts`
  local (line 17); "render placeholder, push post-apply" note (line 32).
- `clusters/centralized_netbox/{variables,outputs,versions}.tf` — representative cluster anatomy:
  sizing `object` vars, count-gated resources + `merge()` `hosts`/`dns_records`/`web_urls` outputs,
  `enabled_features` skip pattern, provider pins (`larstobi/multipass ~>1.4`, `hashicorp/local ~>2.4`,
  `required_version >= 1.7`).
- `clusters/centralized_logging/tests/tofu/sizing_and_render.tftest.hcl` + `tests/testinfra/conftest.py`
  — hermetic `mock_provider`+`command=plan`+`strcontains`/`yamldecode` assertions; live
  `_connect`/`cloud-init status --wait` SSH fixtures built from the `hosts` output.
