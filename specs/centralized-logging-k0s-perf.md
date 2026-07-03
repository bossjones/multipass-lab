# centralized-logging-k0s — CPU/memory spike post-mortem

**Cluster:** `centralized_logging` · **VM:** `centralized-logging-k0s` (4 vCPU / 8G / 50G, Coroot on)
**Date investigated:** 2026-07-03 · **Status:** fixed (see [Fix](#fix))

## Symptom

The k0s VM spiked CPU and memory to near-unresponsiveness:

- **Memory exhausted:** `7.6Gi / 7.7Gi used`, `78Mi free`, `182Mi available`, **no swap**.
- **Load average 15.32** on 4 cores (~4× oversubscribed), trend rising (`15.32, 11.96, 8.63`).
- `multipass exec centralized-logging-k0s` failed with **"No route to host"** (VM too starved to
  answer on the mpqemu channel); direct SSH still worked.
- `k0s kubectl` returned **`net/http: TLS handshake timeout`** talking to its own apiserver — the
  control plane couldn't respond because the node was thrashing.

## Root cause

**OpenEBS NDM (Node Disk Manager) leaks memory without bound, runs unbounded (besteffort, no
memory limit), and triggers a *global* OOM that thrashes the entire VM.**

The single top process was `ndm` (`/usr/sbin/ndm start -v=4 --feature-gates="GPTBasedUUID"`),
part of OpenEBS, at **~4.0 GB RSS (49.6% of RAM)** and ~19% CPU. It runs as a Kubernetes pod in
the **besteffort** QoS class (`/kubepods/besteffort/pod…`, `oom_score_adj=1000`) with **no memory
limit**, so it grows until the whole node is out of memory.

Kernel proof (`journalctl -k`):

```
Out of memory: Killed process 17658 (ndm) total-vm:5443852kB, anon-rss:4024844kB, ... UID:0 oom_score_adj:1000
oom-kill: constraint=CONSTRAINT_NONE, ... global_oom, task_memcg=/kubepods/besteffort/pod…, task=ndm
Tasks in /kubepods/besteffort/pod… are going to be killed due to memory.oom.group
```

`constraint=CONSTRAINT_NONE` + `global_oom` means this was a **whole-node** OOM, not a per-cgroup
limit hit — NDM starved everything else (apiserver, kubelet) before the kernel killed it. NDM then
restarts (`restartCount=1`) and re-grows to ~4 GB over ~2 hours — a repeating
**leak → global OOM → restart** cycle that keeps load pinned high.

### Why NDM is dead weight here

OpenEBS ships two local engines:

| StorageClass      | provisioner        | engine          | needs NDM? | used by Coroot? |
|-------------------|--------------------|-----------------|-----------|-----------------|
| `openebs-hostpath`| `openebs.io/local` | LocalPV hostpath | **no** (makes dirs under `/var/openebs/local`) | **yes — all 6 PVCs** |
| `openebs-device`  | `openebs.io/local` | LocalPV device   | yes (NDM discovers block devices) | **no** |

Every Coroot PVC (`data-coroot-clickhouse-keeper-0/1/2`, `data-coroot-clickhouse-shard-0-0`,
`data-coroot-coroot-0`, `data-coroot-prometheus`) is **`Bound` to `openebs-hostpath`**, served by
the `openebs-localpv-provisioner` Deployment. NDM only backs the `openebs-device` SC, which nothing
uses. NDM is pure overhead.

### How it got installed

`coroot-install.sh` (rendered into `clusters/centralized_logging/cloud-init/k0s-client.yaml.tftpl`)
applies `openebs-operator-lite.yaml` to get a default StorageClass for Coroot's PVCs. That manifest
**bundles NDM** (DaemonSet `openebs-ndm` + `openebs-ndm-node-exporter`, Deployments
`openebs-ndm-operator` + `openebs-ndm-cluster-exporter`) alongside the hostpath provisioner we
actually want. The Coroot resource budget in `specs/coroot.md` never accounted for NDM.

## Fix

Two parts (see the diff on branch `feature-k0s-fixes`):

1. **Strip NDM** — in `coroot-install.sh`, immediately after applying the OpenEBS manifest, delete
   the NDM workloads + the orphan `openebs-device` SC. The hostpath `openebs-localpv-provisioner`
   and `openebs-hostpath` SC are untouched. Apply-then-delete keeps the installer idempotent
   (`just coroot-deploy` re-applies then re-strips in one pass):
   ```bash
   $k -n openebs delete daemonset  openebs-ndm openebs-ndm-node-exporter         --ignore-not-found
   $k -n openebs delete deployment openebs-ndm-operator openebs-ndm-cluster-exporter --ignore-not-found
   $k -n openebs delete configmap  openebs-ndm-config                            --ignore-not-found
   $k delete storageclass openebs-device                                         --ignore-not-found
   ```

2. **Memory-limit guardrails** — in `coroot-values.yaml.tftpl`, add `resources.limits.memory` to
   the Coroot **server**, **node-agent**, and **cluster-agent** (the only components coroot-ce 0.3.3
   exposes a resources knob for — ClickHouse/Prometheus are operator-managed). New vars
   `coroot_server_memory_limit` (2Gi), `coroot_nodeagent_memory` (512Mi),
   `coroot_clusteragent_memory` (256Mi). A future leak now trips the **cgroup** OOM-killer
   (contained + pod restart) instead of a **global** OOM.

### Verified on the live VM (before codifying)

Deleting the NDM workloads on the running VM immediately reclaimed memory and dropped load, with
zero disruption to Coroot:

| metric            | before        | after         |
|-------------------|---------------|---------------|
| memory available  | **78 MiB**    | **~3.7 GiB**  |
| load average (1m) | 15.32         | **0.66**      |
| `ndm` process     | 4.0 GB RSS    | **gone**      |
| Coroot pods       | Running       | Running (0 restarts) |
| Coroot PVCs       | Bound         | Bound (openebs-hostpath) |
| localpv-provisioner | Running     | Running (untouched) |

## How to diagnose this next time

```bash
# on the VM (direct SSH works even when `multipass exec` says "No route to host"):
uptime                                              # load average — >nproc means oversubscribed
free -h                                             # available near 0 + Swap 0B = OOM territory
ps -eo pid,pcpu,pmem,rss,comm --sort=-rss | head    # who owns the RSS
sudo journalctl -k | grep -iE 'killed process|global_oom'   # kernel OOM history + culprit
sudo cat /proc/<pid>/cgroup                         # /kubepods/besteffort/… ⇒ a limitless k8s pod
sudo k0s kubectl get pvc -A -o wide                 # which StorageClass/provisioner is actually used
sudo k0s kubectl -n openebs get ds,deploy,pods      # confirm NDM is/ isn't present
```

Rule of thumb: a **besteffort** pod (no limits) that grows unbounded will cause a
`CONSTRAINT_NONE / global_oom` — the fix is either a memory limit (contain it) or removing it if
it's unused (as here).

## Prevention / follow-ups

- Hermetic test (`tests/tofu/sizing_and_render.tftest.hcl`) asserts the render strips NDM + emits
  limits; live test (`tests/testinfra/test_coroot.py`) asserts no `openebs-ndm` DaemonSet and
  node memory headroom (`> 1000 MiB`).
- **Check other clusters:** anything else applying `openebs-operator-lite.yaml` inherits the same
  latent leak — `grep -rl openebs-operator-lite clusters/`.
- **Lighter future option (not taken):** replace OpenEBS entirely with Rancher
  [local-path-provisioner](https://github.com/rancher/local-path-provisioner) (one ~30 MiB pod vs
  OpenEBS's several) or k0s's built-in `openebs-host-local` storage. Kept OpenEBS-minus-NDM here to
  minimize blast radius and preserve the documented architecture.
- **Swap:** the VM has none, so memory pressure goes straight to OOM. Adding swap would soften that
  but needs `kubelet --fail-swap-on=false`; deferred (removing the leaker is the real fix).

## Reference URLs

- OpenEBS Local PV Hostpath (what we actually use): https://openebs.io/docs/user-guides/local-storage-user-guide/local-pv-hostpath/hostpath-installation
- OpenEBS Node Disk Manager (the leaker; deprecated in OpenEBS 4.x): https://github.com/openebs/node-disk-manager
- Coroot Helm charts / values: https://github.com/coroot/helm-charts · https://docs.coroot.com/
- k0s storage (built-in openebs-host-local option): https://docs.k0sproject.io/stable/storage/
- Rancher local-path-provisioner (lighter alternative): https://github.com/rancher/local-path-provisioner
- Kubernetes resource limits & QoS classes: https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/ · https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/
- Linux cgroup v2 `memory.oom.group` (why the whole pod died): https://docs.kernel.org/admin-guide/cgroup-v2.html#memory-interface-files
- kubelet swap behavior (`failSwapOn`): https://kubernetes.io/docs/concepts/architecture/nodes/#swap-memory

## Related

- `specs/coroot.md` — Coroot design + resource budget (updated to note NDM removal + limits).
- `clusters/centralized_logging/docs/feature-flags.md` — `enable_coroot` + the new `coroot_*_memory` vars.
