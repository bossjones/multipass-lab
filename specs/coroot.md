# Plan: Add Coroot (self-hosted eBPF observability) to the k0s node in `centralized_logging`

## Task Description

Deploy [Coroot](https://github.com/coroot/coroot) — the open-source, **fully self-hosted**,
eBPF-based Kubernetes observability platform (metrics, logs, traces, continuous profiling, a
service map, SLOs, and AI-assisted root-cause analysis) — onto the single-node **k0s** cluster
already running inside `centralized_logging` (the `centralized-logging-k0s` VM). Expose Coroot's
own web UI through an **ingress controller**, which the cluster does not have today and which is
added as part of this work.

This supersedes the earlier Pixie plan. Coroot was chosen over Pixie because it removes Pixie's
two biggest problems on this lab: (1) Pixie's official `px` CLI is **amd64-only** (arm64 404s),
whereas Coroot has shipped **multi-arch (arm64) images since 2022** ([coroot#1](https://github.com/coroot/coroot/issues/1));
and (2) Pixie requires a **cloud account + API keys + interactive auth**, whereas Coroot is
**100% self-hosted with no cloud dependency and no secrets** — so the whole install can be
**declarative in cloud-init**, matching this repo's conventions. As a bonus, the user's "add an
ingress" request now has a concrete purpose: exposing Coroot's UI (Pixie needed no ingress since
its agent only egressed to the cloud).

Added as an opt-in feature flag `enable_coroot` (default `false`) because it is resource-heavy
(bundles Prometheus + ClickHouse). Ingress is a second flag, `enable_ingress` (default `false`).

Reference material (read while writing this plan):
- Repo — https://github.com/coroot/coroot ; node-agent — https://github.com/coroot/coroot-node-agent
- Docs / installation — https://docs.coroot.com/
- Helm charts — https://github.com/coroot/helm-charts (`coroot/coroot-operator`, `coroot/coroot-ce`, `coroot/node-agent`)
- Latest server release `v1.23.3` (2026-07-02); operator chart `0.9.7` / appVersion `1.9.5`.

## Objective

When complete, with `enable_coroot = true` (and `enable_ingress = true`):

```sh
just recreate centralized_logging       # resize k0s VM, install default StorageClass + ingress, deploy Coroot
just coroot-status centralized_logging  # coroot / node-agent / cluster-agent / prometheus / clickhouse pods
just verify  centralized_logging        # live tests confirm the Coroot stack + UI are healthy
just open    centralized_logging        # opens the Coroot UI (+ existing Grafana/Prometheus/etc.)
```

yields a k0s node running the full Coroot stack (server + eBPF node-agent + cluster-agent +
bundled Prometheus + ClickHouse) with its web UI reachable from the host browser via ingress
(or NodePort fallback). All of it gated behind `enable_coroot`/`enable_ingress`, so the default
cluster is byte-for-byte unchanged.

## Problem Statement

The `centralized_logging` cluster runs a single-node k0s VM but has **no application-level /
eBPF observability** — no service map, no auto-captured traces/logs/profiles, no SLO tracking —
and **no ingress controller**, so there is no standard way to expose an in-cluster web UI.

Constraints specific to this lab:

1. **Architecture — low risk (unlike Pixie).** Every Multipass VM is **arm64** (Apple Silicon
   host). Coroot has published multi-arch arm64 images since 2022 and Ubuntu 24.04's 6.8 kernel
   easily clears the eBPF requirements (node-agent needs a modern kernel — 4.16+ for eBPF, 5.x
   for continuous profiling; 6.8 covers all of it). No amd64-only CLI blocker exists. A short
   arm64 smoke check is prudent but is **not** a go/no-go gate.
2. **Storage — Coroot bundles a database.** The `coroot-ce` chart deploys **ClickHouse**
   (traces/logs/profiles) and **Prometheus** (metrics), both requiring **PVCs**. k0s single-node
   has **no default StorageClass**, so one must be installed (OpenEBS `local-hostpath`). Three
   landmines in the chart/manifest defaults must be handled for a laptop VM:
   - **`clickhouse.storage.size` defaults to `100Gi`** — larger than the whole VM disk. Shrink to ~10Gi.
   - **Coroot server `resources.requests.memory` defaults to `4Gi`** — plus ClickHouse (~1–2Gi),
     Prometheus (~1Gi), node-agent (limit 1Gi), cluster-agent. Shrink the server request and size
     the VM to ~8G RAM. We also set explicit **memory *limits*** on the server/node-agent/cluster-agent
     (`coroot_server_memory_limit`/`coroot_nodeagent_memory`/`coroot_clusteragent_memory`) so a
     runaway is OOM-killed in its own cgroup, not via a node-wide OOM.
   - **`openebs-operator-lite.yaml` bundles NDM (Node Disk Manager)** — a block-device scanner only
     the unused LocalPV-*device* engine needs (all our PVCs use hostpath). NDM leaks to ~4Gi
     besteffort and OOM-kills the whole node, so `coroot-install.sh` **deletes it** right after
     applying the manifest. See `specs/centralized-logging-k0s-perf.md`.
3. **Resources.** The k0s VM is currently **2 vCPU / 2G / 20G** — nowhere near enough for
   ClickHouse + Prometheus + Coroot. It must be resized (target **4 vCPU / 8G RAM / 50G disk**).
4. **Exposure.** Coroot's UI is `ClusterIP` on **:8080** by default — not reachable from the host.
   It must be exposed via **NodePort** (simple) or **Ingress** (the user's request). Add
   `ingress-nginx` and configure Coroot's `ingress`, with NodePort as the flag-off fallback.

## Solution Approach

**Install model: operator + `coroot-ce`, fully declarative in cloud-init.** Because Coroot needs
no cloud account and no secrets, the entire install fits the repo's declarative pattern — the same
place k0s itself and kube-state-metrics are already bootstrapped in `k0s-client.yaml.tftpl`. In a
`%{ if enable_coroot ~}` runcmd block (after the existing `k0s kubectl ... readyz` gate):

```sh
# helm (arm64), then the operator, then a minimal Coroot CR via the coroot-ce chart
helm repo add coroot https://coroot.github.io/helm-charts && helm repo update coroot
helm install -n coroot --create-namespace coroot-operator coroot/coroot-operator --version <pinned>
helm install -n coroot coroot coroot/coroot-ce -f /etc/coroot/values.yaml --version <pinned>
```

The `coroot-ce` chart renders a `Coroot` custom resource; the operator then provisions the Coroot
server, the eBPF **node-agent** DaemonSet, the **cluster-agent**, **Prometheus**, and
**ClickHouse** — one install brings up the whole stack. A rendered `/etc/coroot/values.yaml`
(templated by OpenTofu) carries the lab-sized overrides:

```yaml
# /etc/coroot/values.yaml  (rendered from coroot-values.yaml.tftpl)
service:
  type: NodePort          # host-reachable fallback: http://<k0s_ip>:30080
  nodePort: 30080
ingress:                  # rendered only when enable_ingress
  className: nginx
  host: ${coroot_host}    # e.g. coroot.local
  path: /
storage: { size: 5Gi }    # coroot server config store
resources:
  requests: { cpu: 500m, memory: 2Gi }   # down from the 4Gi default
prometheus:
  storage: { size: 8Gi }
clickhouse:
  shards: 1
  replicas: 1
  storage: { size: 10Gi }  # down from the 100Gi default — critical
```

**Storage (required, not optional).** Under `enable_coroot`, install the OpenEBS `local-hostpath`
provisioner and mark its StorageClass **default** (per Pixie's own k0s guide, reused here) so
ClickHouse/Prometheus/Coroot PVCs bind. This runs before the helm install in the same runcmd
sequence.

**Ingress (`enable_ingress`, default `false`).** Install `ingress-nginx` as a hostNetwork
Deployment on the k0s node (binding host :80/:443 is safe — Traefik/:80 lives on the *docker* VM,
not the k0s VM). Coroot's CR then references `ingressClassName: nginx` with a host of
`coroot.local`, reachable via `curl -H 'Host: coroot.local' http://<k0s_ip>/` or an `/etc/hosts`
entry. When `enable_ingress` is off, Coroot is reached via the NodePort (`:30080`) instead — so
Coroot is usable either way and ingress is genuinely decoupled.

**Grafana is de-emphasized (the key difference from the Pixie plan).** Coroot **is** the
dashboard — its own UI is the primary interface, so there is no Grafana datasource plugin to
install. The cluster's existing Grafana/Prometheus/Heimdall stack on the docker VM is left
untouched. Two *optional* integrations are noted as follow-ups (not in the default scope):
(a) expose Coroot's bundled Prometheus via NodePort and add it to the docker VM's Grafana as a
supplementary datasource; (b) point Coroot at an external Prometheus via `externalPrometheus`
instead of its bundled one. Both add coupling for little lab benefit and are deferred.

**Feature-flag / test discipline (mirrors the existing clusters):** `enable_coroot` and
`enable_ingress` are `bool` flags threaded through `local.flags`; hermetic `tofu test` asserts the
cloud-init renders the right blocks per flag with **zero VMs**; live `testinfra` asserts the
running pods/UI and is **skipped** (not failed) when the flag is off — the same pattern the
`enabled_exporters` suite already uses.

## Relevant Files

- `clusters/centralized_logging/variables.tf` — add `enable_coroot` / `enable_ingress` (bool,
  default `false`) and Coroot config vars: `coroot_host` (default `"coroot.local"`),
  `coroot_nodeport` (default `30080`), `coroot_clickhouse_storage` (default `"10Gi"`),
  `coroot_prometheus_storage` (default `"8Gi"`), `coroot_server_memory` (default `"2Gi"`),
  optional pinned chart versions (`coroot_operator_chart_version`, `coroot_ce_chart_version`).
  **No `sensitive` vars — Coroot needs no secrets.**
- `clusters/centralized_logging/main.tf` — add `enable_coroot`/`enable_ingress` to `local.flags`
  (every `templatefile()` already receives `local.flags`); render the Coroot values file (see New
  Files) and thread it + the config vars into the k0s `templatefile()` merge.
- `clusters/centralized_logging/terraform.tfvars` — bump `k0s_client` to
  `{ cpus = 4, memory = "8G", disk = "50G" }`; document `enable_coroot`/`enable_ingress` (kept `false`).
- `clusters/centralized_logging/cloud-init/k0s-client.yaml.tftpl` — add gated blocks: install
  helm (arm64 tarball), write `/etc/coroot/values.yaml`, install OpenEBS default StorageClass, and
  (under `enable_ingress`) apply ingress-nginx; then the helm repo add + operator + coroot-ce
  install — all after the existing `readyz` wait. Reuse the generic `install-exporter.sh`-style
  arch detection already in this template for the helm download.
- `clusters/centralized_logging/outputs.tf` — add the Coroot UI URL to `web_urls` (NodePort
  `http://<k0s_ip>:30080`, or the ingress host) under `enable_coroot`; add a `shell_hints` line;
  add an `enabled_features` output exposing `enable_coroot`/`enable_ingress` for test gating.
- `clusters/centralized_logging/tests/tofu/sizing_and_render.tftest.hcl` — hermetic assertions
  (Coroot/ingress render only when flags on; k0s sizing; ClickHouse storage override present, not `100Gi`).
- `clusters/centralized_logging/tests/testinfra/conftest.py` — expose `enable_coroot`/`enable_ingress`
  (via the new output) so `test_coroot.py` skips when off (mirrors the `enabled_exporters` pattern).
- `Justfile` — add `coroot-status` (pods in the `coroot` ns) and `coroot-deploy` (re-run/repair
  the helm install over SSH) recipes in the existing per-cluster style.
- `CLAUDE.md` / `clusters/centralized_logging/README.md` / `docs/feature-flags.md` — document the
  new flags, the declarative install, ingress vs NodePort exposure, and the "cloud-init edits need
  `just recreate`" reminder.

### New Files

- `clusters/centralized_logging/cloud-init/coroot/coroot-values.yaml.tftpl` — the templated
  `coroot-ce` values shown above (sizing/ingress/nodeport overrides), rendered via `templatefile()`
  and written to `/etc/coroot/values.yaml` on the k0s VM.
- `clusters/centralized_logging/cloud-init/k0s/openebs-sc.yaml` (or inline) — OpenEBS
  `local-hostpath` StorageClass marked default (reused from the Pixie plan's storage step).
- `clusters/centralized_logging/cloud-init/k0s/ingress-nginx.yaml` (or a pinned upstream URL
  applied in runcmd) — ingress-nginx bare-metal/hostNetwork manifest.
- `clusters/centralized_logging/tests/testinfra/test_coroot.py` — live checks (all skipped when
  `enable_coroot` is off): Coroot stack pods Running, node-agent DaemonSet Ready, UI reachable.

## Implementation Phases

### Phase 1: Foundation — resize, storage, ingress (declarative)

VM resize (tfvars), OpenEBS default StorageClass, and the ingress controller — everything the
Coroot install depends on. After this phase a `just recreate centralized_logging` yields a k0s
node with a default StorageClass and (optionally) ingress, ready to receive Coroot.

### Phase 2: Core — deploy the Coroot stack

The templated `coroot-ce` values, helm install of operator + coroot-ce in cloud-init, and the
`coroot-status`/`coroot-deploy` recipes. After this phase the full Coroot stack is running and the
UI is reachable via NodePort/ingress.

### Phase 3: Integration & polish — outputs, tests, docs

`web_urls`/`open` wiring for the Coroot UI, hermetic `tofu test` assertions, live `testinfra`
checks (skipped when off), and documentation. Optionally note the Grafana/external-Prometheus
follow-ups.

## Step by Step Tasks

IMPORTANT: Execute every step in order, top to bottom.

### 1. (Optional but recommended) arm64 smoke check

- On a scratch/resized k0s VM, run the Phase-2 helm install manually and confirm the Coroot,
  node-agent, cluster-agent, Prometheus, and ClickHouse pods reach `Running`/`Ready` on arm64
  (no `exec format error` / `ImagePullBackOff`), and that the UI loads. Record working chart
  versions to pin. This is a confidence check, not a blocking gate.

### 2. Add feature flags + Coroot config vars

- In `variables.tf`, add `enable_coroot` and `enable_ingress` (bool, default `false`) plus the
  Coroot config vars listed under Relevant Files. No secrets.
- In `main.tf`, add both flags to `local.flags`; render the Coroot values file and thread it and
  the config vars into the k0s `templatefile()` merge.

### 3. Bump k0s VM sizing

- In `terraform.tfvars`, set `k0s_client = { cpus = 4, memory = "8G", disk = "50G" }` with a
  comment explaining it hosts Coroot's Prometheus + ClickHouse + server.

### 4. Add the OpenEBS default StorageClass + ingress-nginx to k0s cloud-init

- Under `enable_coroot`, add `write_files` for the OpenEBS operator + `local-hostpath`
  StorageClass (annotated `storageclass.kubernetes.io/is-default-class: "true"`) and
  `k0s kubectl apply` them after the existing `readyz` wait.
- Under `enable_ingress`, add the ingress-nginx manifest (pinned URL or vendored file, hostNetwork)
  and `k0s kubectl apply` it after `readyz`.

### 5. Render the Coroot values file

- Create `cloud-init/coroot/coroot-values.yaml.tftpl` with the sizing/ingress/nodeport overrides.
  Gate the `ingress:` block on `enable_ingress`; always set `service.type=NodePort` +
  `nodePort=${coroot_nodeport}` so the UI is reachable even without ingress.
- In `main.tf`, `templatefile()` it and write it to `/etc/coroot/values.yaml` via cloud-init
  `write_files` (gated on `enable_coroot`).

### 6. Install helm + Coroot in k0s cloud-init

- Under `enable_coroot`, in runcmd (after `readyz` + StorageClass apply): download the arm64/amd64
  helm tarball (reuse the template's `$arch` detection), `helm repo add coroot
  https://coroot.github.io/helm-charts`, `helm install coroot-operator coroot/coroot-operator`,
  then `helm install coroot coroot/coroot-ce -f /etc/coroot/values.yaml`. Pin `--version` for both
  charts using the config vars. Set `KUBECONFIG` from `k0s kubeconfig admin` (or `/var/lib/k0s`
  admin.conf).

### 7. Add `coroot-status` / `coroot-deploy` recipes

- `coroot-status CLUSTER` → `just ssh CLUSTER k0s -- sudo k0s kubectl get pods -n coroot`.
- `coroot-deploy CLUSTER` → re-run the helm upgrade/install over SSH (repair/re-apply without a
  full `just recreate`). Follows the existing per-cluster recipe style.

### 8. Wire outputs, `web_urls`, and `just open`

- In `outputs.tf`, under `enable_coroot`, add the Coroot UI to `web_urls_core`
  (`http://<k0s_ip>:${coroot_nodeport}`, or `http://<k0s_ip>/` with the ingress host noted in a
  `shell_hints` line about the `Host:`/`/etc/hosts` requirement). Add an `enabled_features` output
  for test gating.

### 9. Hermetic tests (`tofu test`)

- In `tests/tofu/sizing_and_render.tftest.hcl` (`mock_provider` + `command = plan`):
  - `enable_coroot = true` ⇒ rendered k0s cloud-init contains the helm install of
    `coroot/coroot-operator` + `coroot/coroot-ce`, the OpenEBS StorageClass, and the values file
    with `shards: 1` and a ClickHouse storage size that is **not** `100Gi`.
  - `enable_coroot = false` (default) ⇒ none of those strings appear.
  - `enable_ingress = true` ⇒ ingress-nginx apply + Coroot `ingress:` block render; false ⇒ absent.
  - k0s sizing reflects the bumped resources.

### 10. Live tests (`testinfra`), skipped when off

- `tests/testinfra/test_coroot.py`, skipped unless `enable_coroot` is true:
  - `k0s kubectl get pods -n coroot` shows `coroot`, `coroot-cluster-agent`, `prometheus`, and
    `clickhouse` pods `Running`, and the `coroot-node-agent` DaemonSet `Ready` on the node.
  - The operator pod is `Running`.
  - The UI answers: `curl -sf http://localhost:30080/` on the k0s host (NodePort), or via ingress
    `curl -sf -H 'Host: coroot.local' http://localhost/` when `enable_ingress`.
  - If `enable_ingress`: the ingress-nginx controller pod is `Running`.

### 11. Validate end-to-end

- Run the Validation Commands below with the flag off (default cluster unchanged) and then on:
  `just recreate centralized_logging` + `just coroot-status` + `just verify`, and confirm the
  Coroot UI loads and shows the node/service map.

### 12. Documentation

- Update `CLAUDE.md`, the cluster `README.md`, and `docs/feature-flags.md` with the flags, the
  declarative install, UI exposure (ingress vs NodePort), and the `just recreate` reminder.

## Testing Strategy

Follow the repo's **two-layer split**:

- **Hermetic (`just check centralized_logging`)** — `mock_provider "multipass"` + `command = plan`,
  no VMs. Assert Coroot/ingress cloud-init + the values file render **only** when their flag is on,
  that the k0s sizing bump is present, and that the ClickHouse storage override replaced the `100Gi`
  default. Must pass with the flag both on and off.
- **Live (`just verify centralized_logging`)** — testinfra over SSH. Assert the Coroot stack pods,
  node-agent DaemonSet readiness, ingress-controller readiness, and UI reachability. The whole
  `test_coroot.py` module **skips** when `enable_coroot` is off.
- **Edge cases:** flag off ⇒ zero Coroot footprint + default VM size (protects the default
  cluster); ClickHouse never provisions a `100Gi` PVC (would exceed disk); PVCs actually bind
  (OpenEBS default StorageClass present); UI reachable via **both** NodePort and ingress paths;
  helm install idempotency (`just coroot-deploy` re-runs safely); `just destroy` teardown (helm
  release + PVCs removed with the VM — no orphaned volumes since PVCs are node-local hostpath).
- **Manual smoke:** open the Coroot UI, confirm the service map populates and traces/logs/profiles
  appear for a workload on the node.

## Acceptance Criteria

- With `enable_coroot = false` (default), `just check` + `just verify centralized_logging` pass and
  the cluster is byte-for-byte unchanged from today (no Coroot, no ingress, default k0s size unless
  the sizing bump is intentionally retained).
- With `enable_coroot = true`: `just recreate centralized_logging` resizes the k0s VM, installs a
  default StorageClass, and deploys the Coroot stack; `just coroot-status` shows `coroot`,
  `coroot-node-agent` (DaemonSet Ready), `coroot-cluster-agent`, `prometheus`, and `clickhouse`
  pods Running.
- The Coroot web UI is reachable from the host — via NodePort (`http://<k0s_ip>:30080`) always,
  and via ingress (`http://<k0s_ip>/` with `Host: coroot.local`) when `enable_ingress = true` —
  and shows the node + service map.
- ClickHouse provisions with the overridden storage size (≈10Gi), **not** the 100Gi default.
- Hermetic `tofu test` asserts every render is correctly gated on its flag (on **and** off).
- New/changed docs describe the flags, the declarative install, and UI exposure.

## Validation Commands

- `just check centralized_logging` — hermetic: `tofu fmt -check` + `validate` + `tofu test` (flag off).
- `tofu -chdir=clusters/centralized_logging test -test-directory=tests/tofu` — hermetic suite
  directly (add `run` blocks toggling `enable_coroot`/`enable_ingress` true).
- `just recreate centralized_logging` — provision + declaratively deploy Coroot (with the flags on).
- `just coroot-status centralized_logging` — Coroot stack pods Running/Ready.
- `just ssh centralized_logging k0s -- sudo k0s kubectl get pvc -n coroot` — PVCs Bound (≈10Gi CH).
- `just verify centralized_logging` — live testinfra incl. `test_coroot.py`.
- `curl -sf -H 'Host: coroot.local' http://<k0s_ip>/ >/dev/null && echo ok` — UI via ingress
  (or `curl -sf http://<k0s_ip>:30080/` for NodePort).
- `just open centralized_logging` — opens the Coroot UI alongside the existing dashboards.

## Notes

- **arm64 is not a blocker** (the reason for switching off Pixie). Coroot images are multi-arch and
  have been since 2022; Ubuntu 24.04's 6.8 kernel exceeds the eBPF/profiling requirements. The
  Step-1 smoke check is a confidence measure, not a go/no-go gate.
- **No secrets, no cloud, no `.env` changes.** Coroot is entirely self-hosted, which is why the
  whole install is declarative in cloud-init (no host-driven deploy, no API keys — the opposite of
  the Pixie plan). Optionally set `authBootstrapAdminPassword` via the values file if a non-default
  admin login is wanted; that would be the only secret and would live in `.env`/`TF_VAR_*`.
- **The two chart-default landmines are the main sizing risk:** ClickHouse `storage.size` defaults
  to **100Gi** (must shrink) and the Coroot server requests **4Gi** memory (shrink to ~2Gi). Both
  are overridden in the rendered values file; the hermetic test guards the ClickHouse one.
- **Ingress now has a real purpose** — exposing Coroot's UI (:8080) — but is still behind its own
  `enable_ingress` flag with a NodePort fallback, so it can be adopted independently. hostNetwork
  ingress-nginx on the k0s VM does not collide with the docker VM's Traefik/:80.
- **Editing cloud-init requires `just recreate`, not `just up`** (already in CLAUDE.md) — and it is
  especially load-bearing here since the entire Coroot bootstrap lives in cloud-init. The cluster
  is currently provisioned, so a `just destroy` + `just up` (i.e. `just recreate`) applies the
  resize and the new gated blocks.
- **Resource budget:** with ClickHouse (`shards:1, replicas:1`) + Prometheus + the Coroot server,
  8G on the k0s VM is the practical floor. Watch for OOMKills in the smoke check and raise to
  10–12G if the Mac has headroom. Keep ClickHouse/Prometheus/Coroot PVCs small (≈10/8/5Gi) to fit
  the 50G disk alongside images.
- **Grafana is intentionally not wired** (Coroot has its own UI). Two optional follow-ups if
  cross-viewing in the existing Grafana is later wanted: expose Coroot's bundled Prometheus via
  NodePort and add it as a Grafana datasource, or run Coroot against an `externalPrometheus`. Both
  are deferred to keep the default install self-contained.
- **New tooling:** `helm` (arm64) is installed into the k0s VM in cloud-init; no host-side CLI is
  required. If a richer host-side `scripts/coroot_cli.py` is later desired, follow the existing
  `grafana_cli.py` uv single-file pattern.
- **Pin chart versions** (`coroot/coroot-operator` `0.9.7` / appVersion `1.9.5`, and a matching
  `coroot-ce`) via the config vars for reproducible `just recreate` runs; the operator otherwise
  auto-updates components.
