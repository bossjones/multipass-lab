# Plan: Netdata Grafana dashboards + human-readable container/process identity

## Task Description

Two related dashboard gaps, in both Grafana-bearing clusters (`centralized_monitoring` and
`centralized_logging`):

1. **Netdata has no Grafana dashboards.** Netdata is already installed on every VM and already
   scraped into each cluster's Prometheus (`job_name: netdata` in monitoring; `logging-netdata` in
   logging — see `specs/netdata-install.md`), so `netdata_*` series are flowing today. But the
   dashboard set (`specs/dashboards.md`) **deliberately skipped** Netdata ("already exposes a full
   self-hosted UI on `:19999`"). The user now wants those scraped metrics surfaced *inside Grafana*
   alongside everything else, so a single Grafana instance answers "what is happening on this box"
   without bouncing to per-VM `:19999` UIs.

2. **Existing dashboards identify containers/processes by opaque IDs.** Several panels key on the
   cAdvisor cgroup path (`id="/"`, `id=~"/kubepods/..."`) or a `name` label that, on the k0s
   (containerd) VMs, resolves to an empty string or a truncated container-hash rather than a
   human-readable pod/container/service name. The task is to re-point those panels (and the new
   Netdata ones) at labels a human can read: `namespace` / `pod` / `container` for Kubernetes,
   `container_label_com_docker_compose_service` (and `name`) for Docker, and — for Netdata — the
   container name Netdata already resolves from the cgroup.

The deliverable is a written spec (this file) plus the concrete dashboard JSON drops and the small
scrape-config relabeling that makes the new identifiers stable across the fleet.

## Objective

When this plan is complete:

- Each cluster's Grafana ships a **`Netdata/` folder** with at least three dashboards — a fleet
  overview, a per-instance deep dive, and a container/cgroup view — all bound to `uid: prometheus`,
  populated from the already-scraped `netdata_*` series, with an `$instance` (and where relevant a
  `$container`) template variable.
- Every panel that previously showed a raw cgroup path or container hash instead shows a
  **human-readable pod / container / compose-service name**, on both the k0s (containerd) and Docker
  VMs.
- The scrape configs attach a stable, friendly `instance`/`nodename` label to Netdata targets so the
  `$instance` picker reads `monitoring-server`, not `host.docker.internal:19999`.
- Both test layers cover the change: hermetic render assertions (new dashboards splice in, datasource
  is `uid: prometheus`, valid YAML/JSON) and a live check that the dashboards provision and that the
  underlying series exist.

## Problem Statement

- **Netdata data is scraped but invisible in Grafana.** The metrics exist in Prometheus; there is no
  pane of glass for them short of N separate `:19999` tabs. Grafana is the intended single overview.
- **Opaque identity defeats the dashboards' stated purpose.** `specs/dashboards.md` says the set
  must let you "tell exactly what is happening on any instance at a glance." A panel that lists
  `id="/kubepods/burstable/pod4f3c.../a91b2c..."` or an empty `name` fails that test — you cannot
  tell *which* workload is hot. The friendly labels are already present in the metrics
  (`pod`, `container`, `namespace`, `container_label_com_docker_compose_service`); the dashboards
  just don't use them.
- **The netdata `instance` label is unfriendly.** Monitoring scrapes the server's netdata via
  `host.docker.internal:19999` (compose gateway) and k0s via a DHCP IP, so the raw Prometheus
  `instance` label is `host.docker.internal:19999` / `10.x.x.x:19999` — useless as a fleet picker
  and inconsistent with the node_exporter `instance` values the other dashboards use.
- **Must honor the repo's conventions.** Drop-a-file provisioning (no `main.tf` edits), fixed
  `uid: prometheus`, no dead panels, two-layer test split, and per-cluster vendoring (the JSON is
  duplicated into each cluster's tree, not shared) — exactly as `specs/dashboards.md` mandates.

## Solution Approach

### A. New Netdata dashboards (drop-a-file, both clusters)

Author custom Netdata dashboards bound to `uid: prometheus`, dropped into
`clusters/<cluster>/cloud-init/grafana/dashboards/Netdata/`. `main.tf` already sweeps
`**/*.json` (`fileset` at `main.tf:150`) and `foldersFromFilesStructure: true` turns the new
subdir into a "Netdata" Grafana folder — **no OpenTofu edit needed**. Prefer custom-authored over
the community grafana.com **7107** import: 7107 is old, targets a different label shape, and would
need heavy trimming to avoid dead panels against *this* stack. Use 7107 only as a panel-idea
reference.

Netdata's Prometheus export (`/api/v1/allmetrics?format=prometheus`, default `average` source)
names series `netdata_<context>_<units>_average{chart,family,dimension,instance}`. The exact names
are **version- and config-dependent** — the plan therefore requires enumerating them against the
*live* endpoint before finalizing panel exprs (see Step 2), the same caution `specs/dashboards.md`
already applies to `syslogng_*` / `file_stat_*`. Representative series to build against:

| Concern | Series (verify live) | Key labels |
|---|---|---|
| Up / uptime | `netdata_system_uptime_seconds_average`, `netdata_info` | `instance` |
| CPU | `netdata_system_cpu_percentage_average` | `dimension` = user/system/iowait/idle |
| Memory | `netdata_system_ram_MB_average` | `dimension` = free/used/cached/buffers |
| Load | `netdata_system_load_load_average` | `dimension` = load1/load5/load15 |
| Disk space | `netdata_disk_space_GB_average` | `family` = mount, `dimension` = avail/used |
| Disk I/O | `netdata_disk_io_KiB_persec_average` | `family` = device, `dimension` = in/out |
| Network | `netdata_net_net_kilobits_persec_average` | `family` = iface, `dimension` = received/sent |
| **Container/cgroup** | `netdata_cgroup_*` (e.g. `..._cpu_..._average`, `..._mem_usage_...`) | **`chart`/`family` carry the container name Netdata resolved** |

The container/cgroup row is the crux of gap #2: Netdata maps each cgroup to its Docker/containerd
container name *before* export, so its `chart`/`family` label is already human-readable
(`cgroup_<name>.cpu`, `family="<name>"`). The container dashboard's `$container` variable is built
from `label_values(netdata_cgroup_..., family)` — no ID ever surfaces.

Proposed files (per cluster, identical JSON duplicated per vendoring):

| File | Title | Answers |
|---|---|---|
| `Netdata/netdata-fleet.json` | Netdata — Fleet | One row per VM: up, uptime, CPU busy %, RAM used %, load1, disk-root used %, net in/out. `$instance` = *all*. |
| `Netdata/netdata-instance.json` | Netdata — Instance | `$instance` picker; per-second CPU (stacked by dimension), RAM breakdown, per-mount disk, per-iface net, disk I/O, load — the realtime deep dive. |
| `Netdata/netdata-containers.json` | Netdata — Containers | `$instance` + `$container` (by resolved **name**); per-container CPU, memory, net, throttling. Zero raw IDs. |

### B. De-ID the existing dashboards (gap #2)

Re-point the container/process identity in the current set to readable labels:

- **`Kubernetes/kubernetes.json`** — the `$Pod`/`$pod` var already exists; ensure it's
  `label_values(kube_pod_info, pod)` (or the cadvisor `pod` label) and that panels group
  `by (namespace, pod, container)` rather than `by (id)`. Drop panels/series that select `id="/"`
  as an identity (keep it only where it legitimately means "the whole node root cgroup").
- **`Instances/cadvisor-k8s.json`** — currently `sum(rate(container_cpu_usage_seconds_total[5m])) by (name)`.
  On containerd `name` is empty; change grouping to `by (namespace, pod, container)` and filter
  `container!="",container!="POD"` so pause containers and the empty-name rollup drop out.
- **`Instances/processes-systemd.json`** — verify process panels key on
  `namedprocess_namegroup_*{groupname=...}` (the process *name*), not a PID; add `$process`
  (`label_values(namedprocess_namegroup_cpu_seconds_total, groupname)`) if useful.
- **Docker `Infrastructure/cadvisor.json`** — already uses friendly `name`; add
  `container_label_com_docker_compose_service` to legends/tables where the raw `name` is a compose
  hash, so the compose service is the primary identifier.

Guiding rule to record in the spec: **identity priority = compose-service / k8s pod+container /
process groupname > `name` > `id`.** Only fall back to `name`/`id` when no friendlier label exists,
and never surface a bare cgroup path or container hash as the *primary* series label.

### C. Friendly `instance` label on Netdata scrape targets

In both Prometheus configs, add `relabel_configs` to the Netdata job so the fleet picker is
readable and consistent with the node_exporter `instance` values:

```yaml
  - job_name: netdata            # (logging-netdata in the logging cluster)
    metrics_path: /api/v1/allmetrics
    params: { format: ["prometheus"] }
    honor_labels: true
    relabel_configs:
      - source_labels: [__address__]
        target_label: instance
        # map host.docker.internal:19999 -> monitoring-server, <k0s_ip>:19999 -> monitoring-k0s
        regex: '(?:host\.docker\.internal|<k0s_ip>):19999'
        replacement: '<friendly-name>'
    static_configs:
      - targets: ["host.docker.internal:19999", "${k0s_ip}:19999"]
```

Simplest robust form: give each target its own `static_configs` block with a
`labels: { instance: <friendly> }`, avoiding brittle regexes. `honor_labels: true` is already set;
confirm it does not clobber the relabeled `instance` (relabel wins — it runs before ingestion).

## Relevant Files

Use these to complete the task:

### `centralized_monitoring`
- `cloud-init/grafana/dashboards/` — **new `Netdata/` subdir** (3 JSONs). Swept automatically.
- `cloud-init/grafana/dashboards/Instances/cadvisor-k8s.json` — regroup `by (name)` → readable labels.
- `cloud-init/grafana/dashboards/Kubernetes/kubernetes.json` — drop `id="/"` identity; use `pod`/`container`/`namespace`.
- `cloud-init/grafana/dashboards/Instances/processes-systemd.json` — confirm `groupname`-based identity.
- `cloud-init/grafana/dashboards/Infrastructure/cadvisor.json` — promote compose-service label.
- `cloud-init/prometheus/prometheus.yml.tftpl:43-52` — add `relabel_configs` (friendly `instance`) to the `netdata` job.
- `cloud-init/grafana/provisioning/datasources/datasources.yaml.tftpl` — reference only (`uid: prometheus` is the binding target; no change).
- `main.tf:149-153` — reference only (fileset sweep; **no edit**).
- `outputs.tf` — `web_urls` already lists the `:19999` endpoints; optionally add the Grafana
  Netdata-folder deep link to `web_urls_core`.

### `centralized_logging` (mirror; self-monitors via its own Grafana on the docker VM)
- `cloud-init/grafana/dashboards/Netdata/` — same 3 JSONs (duplicated per vendoring).
- `cloud-init/grafana/dashboards/{Instances,Kubernetes,Infrastructure}/…` — same de-ID edits.
- `cloud-init/docker-client.yaml.tftpl:186-193` — add relabeling to the inline `logging-netdata`
  job; `instance` friendly names for `central` / `__SELF_IP__` (docker) / `k0s`.
- `cloud-init/prometheus/logging-scrape.yml:54` — mirror the relabel in the cross-cluster reference job.

### Tests & docs
- `clusters/<cluster>/tests/tofu/sizing_and_render.tftest.hcl` — hermetic render assertions.
- `clusters/<cluster>/tests/testinfra/test_e2e_scrape.py` (monitoring) / the logging equivalent —
  live `GET /api/search?type=dash-db` assertions for the new titles/uids.
- `specs/dashboards.md` — update the "Not included: Netdata" note and the inventory table.
- `clusters/centralized_{logging,monitoring}/docs/feature-flags.md` — mention the Grafana Netdata folder.

### New Files
- `clusters/centralized_monitoring/cloud-init/grafana/dashboards/Netdata/{netdata-fleet,netdata-instance,netdata-containers}.json`
- `clusters/centralized_logging/cloud-init/grafana/dashboards/Netdata/{netdata-fleet,netdata-instance,netdata-containers}.json`

## Implementation Phases

### Phase 1: Foundation
Stand up a live cluster and **enumerate the real metric/label names** the running Netdata exposes
(names are version-dependent). Decide the friendly-`instance` naming scheme and confirm the
cgroup→container-name resolution is present in this stack's export.

### Phase 2: Core Implementation
Author the 3 Netdata dashboards against verified series; add scrape relabeling; apply the de-ID
edits to the four existing dashboards.

### Phase 3: Integration & Polish
Duplicate into both clusters, add hermetic + live tests, update `specs/dashboards.md` and
feature-flags docs, and visually confirm via `just open`.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Bring up a reference cluster
- `just up centralized_monitoring` (or `recreate` if cloud-init is stale). Confirm Prometheus has
  the netdata target `up`: `just prometheus-check centralized_monitoring` and/or query
  `/api/v1/targets`.

### 2. Enumerate live Netdata series and labels (authoritative)
- SSH each VM and dump the export:
  `ssh … "curl -fsS localhost:19999/api/v1/allmetrics?format=prometheus"` → save to scratchpad.
- Grep the exact names for cpu/ram/load/disk/net/uptime and, critically, the `netdata_cgroup_*`
  series — confirm `chart`/`family` carry the resolved **container name** (not an ID). Record the
  verified names in a short table appended to this spec (mirrors the `syslogng_*` caution in
  `specs/dashboards.md`).

### 3. Add friendly-`instance` relabeling to the Netdata scrape jobs
- Monitoring `prometheus.yml.tftpl` `netdata` job and logging `docker-client.yaml.tftpl`
  `logging-netdata` job: attach a stable `instance` (e.g. `monitoring-server`, `monitoring-k0s`,
  `logging-central`, `logging-docker`, `logging-k0s`) via per-target `labels:` blocks or
  `relabel_configs`. Mirror into `logging-scrape.yml`.
- `just recreate` the affected cluster; re-verify the target `up` and that `label_values(netdata_info, instance)` returns the friendly names.

### 4. Author `Netdata/netdata-fleet.json`
- `uid: netdata-fleet`, datasource `{ "type": "prometheus", "uid": "prometheus" }` on every panel,
  target, and template var. One table/stat row per `instance`. `$instance` = multi-value, default `.*`.

### 5. Author `Netdata/netdata-instance.json`
- `$instance` single-select from `label_values(netdata_info, instance)`. Time-series for CPU
  (stacked by `dimension`), RAM, per-`family` disk + net, disk I/O, load. All exprs filtered by
  `{instance=~"$instance"}`.

### 6. Author `Netdata/netdata-containers.json`
- `$instance` + `$container` where `$container = label_values(netdata_cgroup_..._average{instance=~"$instance"}, family)`.
- Per-container CPU / memory / net / throttling, legend `{{family}}` (the resolved name). Assert by
  eye that **no panel shows a cgroup path or hash**.

### 7. De-ID the existing dashboards
- `cadvisor-k8s.json`: regroup `by (namespace, pod, container)`, filter `container!="",container!="POD"`.
- `kubernetes.json`: replace `id="/"` identity with `pod`/`container`/`namespace`; fix the `$pod` var query.
- `processes-systemd.json`: ensure process identity is `groupname`; add `$process` if helpful.
- `cadvisor.json` (docker): add `container_label_com_docker_compose_service` to legends/tables.

### 8. Duplicate into the logging cluster
- Copy the 3 Netdata JSONs and the de-ID edits into
  `clusters/centralized_logging/cloud-init/grafana/dashboards/…`. Adjust any monitoring-only panels
  (logging has no Alertmanager) and confirm the `$instance` values match the logging friendly names.

### 9. Hermetic tests
- In each `sizing_and_render.tftest.hcl` add assertions that the rendered server/docker cloud-init
  splices the new `Netdata/netdata-*.json` paths, that a sampled panel declares `uid: prometheus`,
  and that `can(yamldecode(...))` still holds (gz+b64 loop stays valid). Add a negative assertion
  that no de-ID'd dashboard still contains the retired identity selector (e.g.
  `!strcontains(content, "by (name)")` for the k8s cadvisor panel).

### 10. Live tests
- Extend `test_e2e_scrape.py` (and the logging equivalent): `GET /api/search?type=dash-db` includes
  the three Netdata titles/uids; `GET /api/dashboards/uid/netdata-fleet` returns 200; and a
  Prometheus instant query for one `netdata_system_cpu_percentage_average` and one
  `netdata_cgroup_*` series returns data (proves the panels will populate).

### 11. JSON + format validation
- `jq empty` every new/edited JSON. `just check <cluster>` for fmt/validate/hermetic on both clusters.

### 12. Docs
- Update `specs/dashboards.md`: flip the "Not included: Netdata" note, add the `Netdata` folder row
  to the taxonomy + the three files to the inventory, and record the identity-priority rule. Note
  the Grafana Netdata folder in both `docs/feature-flags.md`.

### 13. Visual + final validation
- `just recreate <cluster>` (cloud-init changed) then `just verify <cluster>`; `just open <cluster>`
  and eyeball each new dashboard populates and shows readable names. Run the Validation Commands.

## Testing Strategy

- **Hermetic (`just check <cluster>`)** — no VMs. Assert the new `Netdata/*.json` are spliced into
  rendered cloud-init, a sampled panel binds `uid: prometheus`, the gz+b64 write_files loop stays
  valid YAML (`can(yamldecode(...))`), and the retired identity selectors are gone. Cheap structural
  checks live here per the two-layer rule.
- **Live (`just verify <cluster>`)** — after `just recreate`. Assert the dashboards provision
  (`/api/search`, `/api/dashboards/uid/...`) and that representative `netdata_*` and
  `netdata_cgroup_*` series return data from Prometheus (so panels are guaranteed non-empty). The
  friendly `instance` values are asserted via `label_values(netdata_info, instance)`.
- **Edge cases:** version-drift in `netdata_*` names (mitigated by Step 2 live enumeration);
  containerd empty `name` (the whole point of the de-ID — assert the k8s CPU panel groups by
  `pod`/`container`, not `name`); `honor_labels` vs relabel precedence on `instance` (relabel runs
  first and wins — verify); a VM with zero user containers (container dashboard shows only system
  cgroups — acceptable, not a failure). Panel-level pixel assertions stay out of scope (flaky), same
  as `specs/dashboards.md`.

## Acceptance Criteria

- A `Netdata` Grafana folder with `netdata-fleet`, `netdata-instance`, `netdata-containers` exists
  and populates in **both** clusters, all panels bound to `uid: prometheus`.
- No dashboard (new or existing) surfaces a raw cgroup path or container hash as a primary series
  label; k8s workloads read as `namespace/pod/container`, Docker workloads as the compose service,
  processes as `groupname`, Netdata containers as the resolved name.
- The Netdata `$instance` picker shows friendly names (`monitoring-server`, `logging-k0s`, …), not
  `host.docker.internal:19999`.
- `just check` passes hermetic for both clusters; the live dashboard-provisioned + series-present
  tests pass on at least one cluster; every JSON passes `jq empty`.
- `specs/dashboards.md` and both `feature-flags.md` reflect the additions.

## Validation Commands

- `jq empty clusters/centralized_monitoring/cloud-init/grafana/dashboards/Netdata/*.json` — new JSON is valid.
- `just check centralized_monitoring && just check centralized_logging` — hermetic fmt/validate/test, green.
- `tofu -chdir=clusters/centralized_monitoring test -test-directory=tests/tofu` — run the new render assertions.
- `just recreate centralized_monitoring && just verify centralized_monitoring` — live provision + series-present tests.
- `just prometheus-check centralized_monitoring` — Netdata target `up` after relabeling.
- `just open centralized_monitoring` — visual confirmation the three Netdata dashboards populate with readable names.
- Sanity on the live series (run from the host, IP from `tofu output`):
  `ssh -o StrictHostKeyChecking=no ubuntu@<vm_ip> "curl -fsS localhost:19999/api/v1/allmetrics?format=prometheus | grep -E 'netdata_cgroup_|netdata_system_cpu' | head"`.

## Notes

- **No new libraries.** Pure dashboard JSON + scrape-config edits; testinfra/tofu-test are already wired.
- **Editing cloud-init requires `just recreate`, not `just up`** — the provider keys the VM on the
  cloud-init file path, not its content (CLAUDE.md / `specs/coroot.md`). Dashboards and scrape
  configs both live in cloud-init.
- **Per-cluster vendoring** means the three Netdata JSONs are duplicated into each cluster's tree,
  not shared — consistent with `specs/dashboards.md`. If drift becomes a burden, a follow-up could
  factor them into `clusters/_shared/` like the cross-cluster cloud-init snippets, but that is out of
  scope here.
- **Netdata name resolution** is the linchpin of the de-ID story: Netdata maps cgroups → container
  names itself, so its scraped series are readable *for free*, while cAdvisor needs the label
  regroup. This is worth calling out in the spec as the reason the Netdata container dashboard is the
  cleanest of the set.
- **Do not** import grafana.com 7107 wholesale — it predates this label shape and would ship dead
  panels, violating the "no dead panels" principle. Mine it for panel ideas only.

## References

- Netdata Prometheus export (metric/label naming) — https://learn.netdata.cloud/docs/exporting-metrics/prometheus
- Netdata charts model — https://learn.netdata.cloud/docs/dashboards-and-charts/charts
- Netdata containers & cgroups (name resolution) — https://learn.netdata.cloud/docs/collecting-metrics/containers-and-cgroups
- Netdata Grafana plugin (alt datasource path, not used here) — https://learn.netdata.cloud/docs/dashboards-and-charts/grafana-plugin
- Community dashboard 7107 (panel-idea reference only) — https://grafana.com/grafana/dashboards/7107-netdata/
- Existing dashboard architecture — `specs/dashboards.md`
- Netdata install/scrape wiring — `specs/netdata-install.md`
