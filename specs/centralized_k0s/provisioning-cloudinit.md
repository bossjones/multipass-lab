# centralized_k0s — provisioning & cloud-init research

> Research shard: **`provisioning-cloudinit`** (1 of 5). Scope: how to bootstrap the 6-VM HA
> k0s cluster on Multipass (arm64 Mac, Proxmox-bound) using the repo's OpenTofu + cloud-init
> idioms. Sibling shards (networking/CPLB, storage/Velero, CNI, testing) are out of scope here.

## Summary

The 6-VM target is **3 controllers (stacked etcd quorum) + 3 workers**. The repo's existing k0s
usage is *single-node* (`k0s install controller --single`), which uses **kine+SQLite and
cannot form a quorum** — HA is a hard switch to `spec.storage.type: etcd`. The single hardest
problem is **not** rendering config; it is **join sequencing + shared PKI across VMs that boot
in parallel under Multipass**, where the repo's silent boot-race failure mode is strictly worse
than in the single-node clusters.

Two viable bootstrap models exist, and they map cleanly onto two things the repo already does:

1. **Pure per-VM cloud-init + pre-shared join tokens** — everything is rendered by OpenTofu and
   baked into each VM's cloud-init; no host orchestration. Feasible because k0s's
   `k0s token pre-shared` + the documented **custom-CA pre-generation** flow let you compute
   tokens and lay down PKI *before any controller is running*. Matches the repo's "everything in
   cloud-init" purity but forces the repo to own PKI generation and the k0s token/secret format.
2. **cloud-init (OS prep) + k0sctl (cluster formation) post-apply** — a `terraform_data` SSH step
   (exactly the shape of the existing `terraform_data.k0s_log_shipper` in the logging cluster)
   renders a `k0sctl.yaml` from `tofu output` IPs and runs `k0sctl apply`. k0sctl distributes
   CA/SA keys automatically and enforces controller→controller→worker join order for free.

**Recommendation: the hybrid (Model 2).** Let cloud-init do what it is already good at (per-VM
OS prep, the DNS warm-up gate, the retryable `get.k0s.sh` install, CA trust, exporters) and let
**k0sctl own only cluster formation** (key distribution + etcd join order). This keeps the
byte-fragile parts (PKI, join-order, etcd membership) inside a tool built for them, keeps the
repo's boot-race guard intact for the binary download, and reuses the repo's existing
post-apply-SSH precedent. Pure cloud-init (Model 1) is documented below as the "zero host
orchestration" alternative and as adversarial bait.

---

## k0sctl vs cloud-init (recommendation)

### The core tension

The repo model is: OpenTofu renders each VM's cloud-init from `.tftpl`, injects peer IPs
discovered at apply time (`multipass_instance.central.ipv4` → `templatefile` → `local_file`),
and `multipass launch` blocks until cloud-init is `done`. There is **no cross-VM coordination
primitive** in cloud-init: 6 VMs boot in parallel and cannot wait on each other except by polling
over the network. k0s HA fundamentally needs ordering (controller-1's etcd must exist before
controller-2 joins it) and **identical CA/SA/etcd-CA keypairs on all three controllers**
(`/var/lib/k0s/pki/{ca.crt,ca.key,sa.pub,sa.key,etcd/ca.crt,etcd/ca.key}`). Those two facts are
what make "just render 6 cloud-inits" harder than it looks.

### Model 1 — pure per-VM cloud-init + pre-shared tokens (sketch)

k0s supports **generating join tokens before the cluster is up** via pre-shared tokens, and
supports **pre-generating the CA** offline (from the custom-CA doc):

```bash
# tokens can be minted without a running controller, against a KNOWN ca.crt + KNOWN url:
k0s token pre-shared --role worker     --cert /var/lib/k0s/pki/ca.crt --url https://<c1-ip>:6443/
k0s token pre-shared --role controller --cert /var/lib/k0s/pki/ca.crt --url https://<c1-ip>:9443/
```

`k0s token pre-shared` emits two artifacts: the **token file** (handed to the joiner) and a
**bootstrap Secret manifest** that must be dropped into controller-1's
`/var/lib/k0s/manifests/<stack>/` so the token is honoured. So the OpenTofu flow would be:

1. Generate the shared CA/SA/etcd-CA once at plan/apply time (a `null_resource`/`terraform_data`
   running the documented `openssl` block, or the `hashicorp/tls` provider), persisted like
   `centralized_pki`'s `init_ca.py` persists step-ca material into a gitignored
   `*.auto.tfvars`, so the keys are stable across `just recreate`.
2. Create controller-1 first (dependency edge → its DHCP IP is known), then render every other
   VM's cloud-init with a pre-shared token pointing at controller-1's IP (or the CPLB VIP).
3. `write_files` the shared PKI into `/var/lib/k0s/pki/**` on all three controllers, and the
   bootstrap-secret manifests into controller-1's `/var/lib/k0s/manifests/`.
4. Each joiner's `runcmd` runs `k0s install controller --token-file …` / `k0s install worker
   --token-file …`, wrapped in the repo's retry+gate idiom, retrying until controller-1's API
   answers.

**Pros:** zero host orchestration; a plain `just up centralized_k0s` forms the whole cluster;
fits `mock_provider` hermetic tests (assert rendered cloud-init contains the right SANs/tokens
with `command = plan`, no VM). **Cons:** the repo now owns PKI generation *and* must reproduce
k0s's token/bootstrap-secret format exactly; the etcd join order across parallel boots is handled
only by polling/retry (works, but every controller-2/3 `runcmd` spins until controller-1 is
`/readyz`); secrets (ca.key, sa.key) land in rendered `local_file`s under `.rendered/`
(gitignored, but on-disk plaintext).

### Model 2 — cloud-init OS prep + k0sctl formation post-apply (RECOMMENDED, sketch)

Cloud-init per VM does **only** OS-level prep (identical shape to today's k0s templates):

```
runcmd:
  - timedatectl set-timezone Etc/UTC
  # DNS warm-up gate (unchanged repo idiom) — see "Boot-race hardening" below
  # retryable binary install, but DO NOT `k0s install`/`k0s start` here:
  - |
    for i in $(seq 1 5); do
      curl -sSLf https://get.k0s.sh | K0S_VERSION=v1.34.9+k0s.0 sh && break
      echo "k0s install attempt $i failed; retrying"; sleep 5
    done
  - update-ca-certificates   # internal_ca_cert trust (unchanged)
```

Then a `terraform_data`/`null_resource` (mirroring `terraform_data.k0s_log_shipper`) renders a
`k0sctl.yaml` from `tofu output` hosts and runs it from the Mac over SSH:

```hcl
resource "terraform_data" "k0s_bootstrap" {
  depends_on = [multipass_instance.controllers, multipass_instance.workers]
  triggers_replace = { hosts = jsonencode(local.k0s_hosts) }
  provisioner "local-exec" {
    command = "k0sctl apply --config ${local_file.k0sctl_yaml.filename} --no-wait=false"
  }
}
```

k0sctl over SSH: installs/uploads the pinned k0s binary, **distributes CA/SA keys to every
controller automatically**, enforces the controller→controller→worker join order, and writes the
admin kubeconfig back. This is the officially recommended multi-node path.

**Pros:** k0sctl owns the byte-fragile parts (PKI distribution, etcd membership order); no need to
reproduce k0s token internals; robust ordering regardless of boot race; `k0sctl reset`/`backup`
come along. **Cons:** needs `k0sctl` on the Mac (a `just` preflight check + Homebrew hint); adds a
post-apply step so `just up` alone does not finish the cluster (already true for cross-cluster
wiring, so `just up-connected` semantics fit); all 6 VMs' SSH must be reachable (they are — the
repo drives VMs by IP over SSH). **Hermetic-test note:** the `k0sctl apply` step can't run under
`mock_provider`; keep the rendered `k0sctl.yaml` (a `local_file`) as the hermetic assertion
target (`command = plan` checks addresses/version/`storage.type: etcd`), and gate the actual
apply behind the live `just verify` layer.

> **Recommended split:** Model 2, but keep the `get.k0s.sh` download + DNS gate + CA trust in
> cloud-init (so a VM is "k0s-binary-ready" the moment it boots) and let k0sctl do *only*
> `k0s install`+join+key-distribution. Best of both: the boot-race guard stays where it works,
> and cluster formation stays in a tool designed for it.

---

## Per-controller k0s.yaml templating

Under DHCP, controller IPs are only known at apply time — so `k0s.yaml` is rendered exactly like
the repo already renders the syslog-ng `client_conf` (runtime-IP-injection): create the
controllers, read `multipass_instance.<c>.ipv4`, `templatefile()` per controller into
`.rendered/`, write via `local_file`.

**Cluster-level fields — MUST be byte-identical on all controllers** (differences here corrupt the
cluster): `spec.storage.type: etcd`, `spec.network.provider/podCIDR/serviceCIDR`,
`spec.network.controlPlaneLoadBalancing` (CPLB/Keepalived VIP), `spec.api.externalAddress` (the
VIP or external LB — **only if not using CPLB VirtualServers**), and `spec.api.sans` (should list
*every* controller IP + the VIP on *every* controller).

**Node-specific fields — differ per controller:** `spec.api.address` (this controller's IP) and
`spec.storage.etcd.peerAddress` (this controller's IP).

Templating strategy (one `.tftpl`, rendered N times):

```hcl
locals {
  controller_ips = [for c in multipass_instance.controllers : c.ipv4]   # runtime IPs
  k0s_sans       = concat(local.controller_ips, [var.cplb_vip])         # identical everywhere
}
resource "local_file" "k0s_yaml" {
  for_each = { for i, c in multipass_instance.controllers : i => c }
  filename = "${local.render_dir}/k0s-controller-${each.key}.yaml"
  content  = templatefile("${path.module}/cloud-init/k0s.yaml.tftpl", {
    api_address   = each.value.ipv4          # node-specific
    peer_address  = each.value.ipv4          # node-specific
    sans          = local.k0s_sans           # cluster-level (identical)
    pod_cidr      = var.pod_cidr             # cluster-level
    service_cidr  = var.service_cidr         # cluster-level
    cplb_vip      = var.cplb_vip             # cluster-level
    storage_type  = "etcd"                   # cluster-level
  })
}
```

Reference `k0s.yaml` (per docs — note `port: 6443`, `k0sApiPort: 9443`):

```yaml
apiVersion: k0s.k0sproject.io/v1beta1
kind: ClusterConfig
metadata: { name: k0s }
spec:
  api:
    address: ${api_address}          # node-specific
    port: 6443
    k0sApiPort: 9443
    sans:                            # cluster-level: ALL controller IPs + VIP, on every node
      %{ for s in sans ~}
      - ${s}
      %{ endfor ~}
  storage:
    type: etcd                       # cluster-level — NOT kine (kine+SQLite can't form quorum)
    etcd:
      peerAddress: ${peer_address}   # node-specific
  network:
    provider: kuberouter             # cluster-level
    podCIDR: ${pod_cidr}
    serviceCIDR: ${service_cidr}
    # CPLB/NLLB config is a sibling shard's call; addresses templated the same way.
```

With Model 2, this same rendered config is what `k0sctl.yaml`'s `spec.k0s.config` embeds (k0sctl
pushes one config; per-node `address`/`peerAddress` come from each host's `ssh.address`). With
Model 1 each controller reads its own `/etc/k0s/k0s.yaml` at `k0s install controller -c …`.

---

## Join order & tokens on Multipass

**Required order:** controller-1 bootstraps (creates the etcd cluster) → controllers 2 & 3 join
with `--role=controller` tokens (k0s auto-adds each as an etcd member) → workers join with
`--role=worker` tokens. A **2-controller** control plane is API-HA but **not etcd-HA** (no quorum
with one down) — go straight to 3.

**Token creation** (post-bootstrap path, Model 2 / manual):
```bash
k0s token create --role=controller --expiry=1h > controller.token   # for c2, c3
k0s token create --role=worker                  > worker.token       # for workers
# join:
k0s install controller --token-file controller.token -c /etc/k0s/k0s.yaml   # c2/c3 (etcd/kine required)
k0s install worker     --token-file worker.token                            # workers
k0s worker --token-file k0s.token   # (foreground/service variant)
```

**Sequencing across 6 parallel-booting VMs** — this is the crux, and the repo's silent-wait-loop
failure mode (a failed early step never aborts `/bin/sh` runcmd, so a later `until` loops forever)
makes naive ordering dangerous:

- **Model 2 (recommended):** k0sctl performs ordering itself over SSH — it waits for controller-1's
  API before joining c2/c3, and for the control plane before workers. Cloud-init on each VM only
  needs to reach "k0s binary installed + OS ready"; no cross-VM `until` loop in cloud-init at all.
  This removes the ordering problem from the boot race entirely.
- **Model 1 (pure cloud-init):** controller-1's cloud-init runs `k0s install controller` + lays
  down the pre-shared bootstrap-secret manifests. c2/c3/workers' cloud-init **must gate on
  controller-1** before joining, e.g.:
  ```
  # after DNS gate + binary install, BEFORE `k0s install … --token-file`:
  - |
    for i in $(seq 1 120); do
      curl -sk https://<c1-ip>:6443/readyz >/dev/null 2>&1 && break
      echo "waiting for controller-1 API ($i)"; sleep 5
    done
  ```
  Use a **bounded** loop (`seq 1 120`, ~10 min) not `until … ; do sleep 5; done`, so a genuinely
  dead controller-1 fails the VM instead of hanging `tofu apply` forever with no `--failed` unit.

**Do NOT** rely on `depends_on` between `multipass_instance`s to serialize *provisioning* — the
dependency edge only serializes *creation/IP-availability*; `multipass launch` returns when
cloud-init is `done`, which for controller-1 includes etcd being up, so a `depends_on` chain
(c1 → c2 → c3 → workers) actually *does* give a usable serialization in Model 1 at the cost of a
slower `up`. Prefer k0sctl's in-tool ordering over abusing tofu graph edges.

---

## CA/SA key distribution

All controllers **must** share identical `ca.crt/ca.key/sa.pub/sa.key` and etcd `ca.crt/ca.key`.
The rotation doc is explicit: *"Copy over the following files from the first controller to each of
the remaining controllers: `ca.crt`, `ca.key`, `sa.pub`, `sa.key`"* (plus etcd CA). Three options:

1. **k0sctl auto-distribution (Model 2, recommended).** k0sctl generates the CA on the first
   controller and copies the keypairs to the others as part of `apply`. Zero repo-side PKI code.
2. **Pre-generate + inject via cloud-init (Model 1).** Generate once (the documented `openssl`
   block, or `hashicorp/tls`), persist like `centralized_pki`'s `init_ca.py`
   (gitignored `*.auto.tfvars`, survives `just recreate`), then `write_files` the material into
   `/var/lib/k0s/pki/**` (and `/var/lib/k0s/pki/etcd/**`) on all three controllers **before**
   `k0s install`. Fully declarative, static across rebuilds, no ordering needed for keys.
   ```bash
   # (docs) pre-generate — same block runs once, output pinned into a tfvars:
   mkdir -p /var/lib/k0s/pki/etcd && cd /var/lib/k0s/pki
   openssl genrsa -out ca.key 2048
   openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -out ca.crt -subj "/CN=k0s CA"
   openssl genrsa -out sa.key 2048
   openssl rsa -in sa.key -outform PEM -pubout -out sa.pub
   cd etcd && openssl genrsa -out ca.key 2048 && \
     openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -out ca.crt -subj "/CN=k0s etcd CA"
   ```
   Permissions matter: `ca.key`/`sa.key` must be `0600` root — set via `write_files: permissions`.
3. **Generate-once-and-scp (post-apply).** Let controller-1 self-generate, then a `terraform_data`
   SSH step scps `/var/lib/k0s/pki/{ca,sa,etcd/ca}.*` to c2/c3 before they join. This is basically
   a hand-rolled k0sctl — prefer real k0sctl.

**Recommendation:** Model 2's automatic distribution unless the "no host orchestration" property
is required, in which case option 2 (pre-generate + cloud-init inject, persisted like the step-ca
material) is the clean declarative fit.

---

## Boot-race hardening for 6 VMs

The repo's canonical failure (`triage-patterns` Example 4b): `runcmd` is `/bin/sh` with **no
`set -e`**, so a failed `curl https://get.k0s.sh` (typically a first-boot DNS warm-up race:
`Could not resolve host: get.k0s.sh`) does **not** abort — a later `until … /readyz; do sleep 5;
done` then loops forever, the VM sits `cloud-init: running` / `degraded running` with **no
`--failed` unit**, and `tofu apply` prints `Still creating [Nm]` on an already-`Running` VM. With
6 VMs this is 6× the exposure. Copy the existing guard shape verbatim:

```yaml
%{ if dns_server != "" ~}
  - systemctl restart systemd-resolved
  - |
    for i in $(seq 1 30); do getent hosts get.k0s.sh >/dev/null 2>&1 && break; sleep 2; done
%{ endif ~}
  - |
    for i in $(seq 1 5); do
      curl -sSLf https://get.k0s.sh | K0S_VERSION=v1.34.9+k0s.0 sh && break
      echo "k0s install attempt $i failed; retrying"; sleep 5
    done
```

Additional 6-VM hardening:

- **Bound every cross-VM wait.** Any "wait for controller-1" loop must be `for i in $(seq 1 N)`
  with a ceiling + a nonzero exit on exhaustion, never `until … ; do sleep …; done`. An unbounded
  wait on a peer that failed = a permanently hung `tofu apply`.
- **Prefer removing the wait entirely (Model 2).** If k0sctl owns join order, no controller VM's
  cloud-init waits on any other — the biggest single reduction in 6-VM boot-race surface.
- **`K0S_VERSION` pins the download** so a transient `get.k0s.sh` fetch of "latest" can't drift
  mid-fleet (see Version pin). The installer honours `K0S_VERSION=<pin> sh`.
- **`just recreate`, not `just up`, after editing cloud-init** (repo rule): tofu won't recreate a
  `multipass_instance` when only the rendered `local_file` changes, so a plain `just up` reuses
  stale cloud-init and live tests fail confusingly.
- **Stale `.cross-cluster.auto.tfvars.json`** poisons both `just check` and `just up` here too
  (dead hub IP → resolver can't resolve → installs hang looking exactly like a boot race). Same
  `just unwire` / `destroy-all` mitigations apply to this cluster.
- **Triage:** `cloud-init status --long` (→ `degraded running`), `ps -o pid,ppid,args -ax | grep
  runcmd` (live runcmd proc + child `sleep` = looping), read
  `/var/lib/cloud/instance/scripts/runcmd`, then `grep -nE 'Could not resolve|not found'
  /var/log/cloud-init-output.log`. `/system-debug centralized_k0s <role>` shells out to `ssh`
  (sidesteps the macOS Local-Network block on uv CLIs).

---

## Version pin

Today the repo is **unpinned** (`curl https://get.k0s.sh | sh` = latest), which is a fleet-drift
risk (different VMs could pull different "latest" builds during a rolling boot). **Pin an explicit
`vX.Y.Z+k0s.0`** and pass it as `K0S_VERSION` to the installer.

- **Recommended pin: `v1.34.9+k0s.0`** (Kubernetes 1.34.x, **etcd 3.6.12**). It is the version the
  Proxmox brief's k0sctl example already uses, keeping lab↔Proxmox parity.
- **etcd 3.5→3.6 hop caveat.** k0s **1.33 ships etcd 3.5.x**, k0s **1.34 ships etcd 3.6.x**. Per
  etcd guidance you must be on **etcd ≥ 3.5.26 before moving to 3.6** to avoid "zombie member"
  quorum loss. A *fresh* 1.34 build has no upgrade path to traverse, so a greenfield
  `v1.34.9+k0s.0` cluster is safe — the caveat only bites a future **in-place 1.33→1.34 upgrade**.
  Document it so the eventual upgrade runbook does the intermediate `≥3.5.26` hop.
- k0s cadence: new minor every ~4 months, each maintained ~14 months; k0s supports the last three
  Kubernetes minors. Pin one version repo-wide (a `k0s_version` var, default `v1.34.9+k0s.0`),
  thread it into the `get.k0s.sh` `K0S_VERSION` and into `k0sctl.yaml`'s `spec.k0s.version`, and
  re-verify against docs at execution time (versions move fast).

---

## No-SELinux note

**Confirmed N/A.** The k0s SELinux doc applies **only to SELinux-enabled distros (CentOS/RHEL)**,
where SELinux is on by default and you must install `container-selinux`, relabel k0s dirs
(`container_runtime_exec_t`, `container_var_lib_t`), and set `enable_selinux = true` in
containerd. **Ubuntu uses AppArmor**, not SELinux, so none of that applies to this Multipass
lab (Ubuntu 24.04) or a typical Ubuntu Proxmox guest. The one adjacent requirement that *does*
apply: k0s's soft dependency on **AppArmor** — containerd wants `/sbin/apparmor_parser` present
when AppArmor is enabled (it is, on stock Ubuntu; already satisfied). No action needed; note it in
the spec so a future RHEL/Rocky Proxmox target knows to revisit the SELinux doc.

---

## Open risks / adversarial-bait

- **`k0s install controller --single` ≠ HA.** `--single` disables multi-node features and pins
  kine+SQLite — *"the cluster cannot be extended."* The 6-VM cluster must **not** use `--single`;
  it must use `spec.storage.type: etcd`. Storage backend is effectively **immutable after init**
  (kine↔etcd is a rebuild, not a migration) — decide etcd up front.
- **CNI is immutable after init too.** kube-router vs Cilium must be chosen before the first
  `k0s install`. (Sibling shard's decision — flagged so provisioning doesn't hard-code it.)
- **cgroup v2 required.** k0s fails pre-flight without cgroup v2 + controllers
  `cpu,cpuacct,cpuset,memory,devices,freezer,pids`. Ubuntu 24.04 is cgroup-v2 by default — verify
  on the Multipass image; a cgroup-v1 image would fail all 6 workers identically.
- **Sizing.** Docs' minimums (controller 1 vCPU/1 GB, worker 1 vCPU/0.5 GB) are *floors* for an
  idle cluster; stacked etcd + real workloads need more. On the arm64 Mac, 6 VMs at the existing
  `local.k0s_size` Coroot floor (4 vCPU/8 GB/50 GB each) would be 24 vCPU/48 GB — **likely
  oversubscribes the laptop**. Right-size per role (controllers lighter than workers) and make it
  a var; the Proxmox target has headroom the Mac does not. (`aarch64` is a first-class supported
  arch — no arch risk.)
- **Secrets on disk (Model 1).** Rendered `ca.key`/`sa.key` land in `.rendered/*` and a persisted
  `*.auto.tfvars` (both gitignored, but plaintext on the Mac). Acceptable for a throwaway lab
  (same posture as the pinned NetBox token + step-ca material) — **do not** carry the pattern to
  Proxmox.
- **`k0s install` ignores env vars.** Proxy/`K0S_*` config for the *running service* must go via a
  systemd drop-in, not the install command. `K0S_VERSION` works only because it's consumed by the
  `get.k0s.sh` shell script, not by `k0s install`.
- **k0sctl is another host tool to preflight** (Model 2). `just up-connected` must check for it
  (like `tofu`/`multipass`/`uv`) and hint `brew install k0sproject/tap/k0sctl`. Its `apply` step
  can't run under `mock_provider`, so hermetic tests must assert on the rendered `k0sctl.yaml` /
  `k0s.yaml` `local_file`s (`command = plan`), and the real formation goes in the live `verify`
  layer — pin every opt-in var OFF in each `tests/tofu/*.tftest.hcl` file-level `variables {}`.
- **No default StorageClass.** k0s ships **no built-in CSI/StorageClass**; anything needing a PVC
  (out of scope here, but relevant to workers) needs OpenEBS/local-path — and k0s's kubelet dir is
  the non-standard `/var/lib/k0s/kubelet`, which CSI drivers must be told about. (Storage shard.)
- **Manifest deployer / Helm as the addon path.** For anything to auto-install at bootstrap
  (ingress, storage), prefer the k0s-native paths over ad-hoc `runcmd` kubectl: drop YAML into a
  direct-child dir of `/var/lib/k0s/manifests/<stack>/` (watched, auto-applied, deletion-tracked;
  nested subdirs ignored) or declare `spec.extensions.helm` in `k0s.yaml`. This is cleaner than
  the current single-node `coroot-install.sh` runcmd approach and survives restarts.

---

## Sources

- k0s docs — Install / quick-start: <https://docs.k0sproject.io/stable/install/>
  (`--single` disables extension; `--enable-worker --no-taints`; `k0s start`; `get.k0s.sh`).
- k0s docs — Configuration: <https://docs.k0sproject.io/stable/configuration/>
  (cluster-level vs node-specific fields; `spec.api.{address,sans,externalAddress,port,k0sApiPort}`;
  `spec.storage.{type,etcd.peerAddress}`; `spec.network.*`; CPLB/NLLB example).
- k0s docs — Worker node config: <https://docs.k0sproject.io/stable/worker-node-config/>
  (`k0s worker --token-file`, `--labels`, `--taints`, `--kubelet-extra-args`, worker profiles).
- k0s docs — Custom CA: <https://docs.k0sproject.io/stable/custom-ca/>
  (`/var/lib/k0s/pki/{ca,sa,etcd/ca}.*`; `openssl` pre-generation block;
  `k0s token pre-shared --role … --cert … --url …`; controllers use `:9443`).
- k0s docs — CA troubleshooting/rotation:
  <https://docs.k0sproject.io/stable/troubleshooting/certificate-authorities/>
  (CA/SA must be identical across controllers; copy `ca.crt/ca.key/sa.pub/sa.key`; reboot
  `--enable-worker` controllers on rotation).
- k0s docs — High availability: <https://docs.k0sproject.io/stable/high-availability/>
  (2-node = API-HA only; 3 or 5 for etcd HA; TCP LB on 6443/8132/9443; `spec.api.externalAddress`).
- k0s docs — SELinux: <https://docs.k0sproject.io/stable/selinux/> (CentOS/RHEL only; N/A Ubuntu).
- k0s docs — External runtime deps: <https://docs.k0sproject.io/stable/external-runtime-deps/>
  (kernel ≥4.3, cgroup v2 required + controllers; AppArmor `apparmor_parser` soft dep).
- k0s docs — System requirements: <https://docs.k0sproject.io/stable/system-requirements/>
  (controller 1 vCPU/1 GB, worker 1 vCPU/0.5 GB floors; `aarch64` supported; Ubuntu 20.04/22.04/24.04).
- k0s docs — Environment variables: <https://docs.k0sproject.io/stable/environment-variables/>
  (`k0s install` ignores env vars → use systemd drop-ins; proxy + component-prefixed vars).
- k0s docs — Storage: <https://docs.k0sproject.io/stable/storage/>
  (no bundled CSI/StorageClass; kubelet dir `/var/lib/k0s/kubelet`).
- k0s docs — Manifest deployer: <https://docs.k0sproject.io/stable/manifests/>
  (`/var/lib/k0s/manifests/<stack>/*.yaml` auto-applied; Helm via `spec.extensions.helm`).
- Repo — `clusters/centralized_logging/cloud-init/k0s-client.yaml.tftpl`,
  `clusters/centralized_monitoring/cloud-init/k0s-client.yaml.tftpl` (DNS warm-up gate + retry
  loop; single-node `k0s install controller --single`; kubeconfig/k9s/stern idioms).
- Repo — `clusters/centralized_logging/main.tf` (runtime-IP-injection via
  `multipass_instance.central.ipv4` → `templatefile` → `local_file`; `local.k0s_size` auto-bump).
- Repo — `ai_docs/claude-multipass-infra-upgrade-brief.md` (Option 2 HA target: 3 controllers +
  stacked etcd + CPLB/NLLB; `k0sctl.yaml`; controller/worker token flow; `v1.34.9+k0s.0`;
  etcd 3.5→3.6 ≥3.5.26 hop).
- Repo — `CLAUDE.md` (boot-race silent-wait-loop rule; `just recreate` vs `just up`; stale
  `.auto.tfvars` poisoning; hermetic `mock_provider`/`command = plan` test layer).

K0S-RESEARCH-DONE: provisioning-cloudinit | Recommend hybrid — cloud-init does OS prep + DNS-gated retryable get.k0s.sh binary install, k0sctl (post-apply terraform_data, like k0s_log_shipper) owns etcd join order + CA/SA distribution across 3 controllers + 3 workers on pinned v1.34.9+k0s.0 (etcd 3.6); pure-cloud-init + pre-shared tokens is the zero-orchestration alternative; SELinux N/A on Ubuntu/AppArmor.
