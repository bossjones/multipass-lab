# Spec: Grafana Dashboards

## Context

Both lab clusters run Grafana, but each shipped only **two skeletal 2-panel starter
dashboards** (`node-exporter.json`, `cadvisor-k8s.json`) hand-wired one file at a time
through OpenTofu. There was no per-instance overview, and most of the exporters the
clusters already install (process, kube-state-metrics, kubelet, blackbox, statsd, ssh,
filestat, syslog-ng) had no dashboard at all. The goal of this work is a dashboard set
that lets you **tell exactly what is happening on any instance at a glance** — CPU,
memory, disk, network, load, uptime, top processes, systemd unit health, containers,
and (on k0s hosts) Kubernetes state — plus deep-dive dashboards per subsystem.

This is a **hybrid** set: a small number of custom-authored dashboards (guaranteed to
bind and populate against this exact stack) plus curated, well-known community
dashboards imported from [grafana.com](https://grafana.com/grafana/dashboards/).

## Design principles

1. **Drop-a-file provisioning.** Adding a dashboard is a single `.json` drop into the
   cluster's `cloud-init/grafana/dashboards/<Folder>/` directory — no OpenTofu edits.
   `main.tf` sweeps the directory with `fileset(..., "**/*.json")` and cloud-init writes
   each file (gzip+base64) to `/var/lib/grafana/dashboards/<Folder>/`.
2. **Folders from file structure.** The Grafana file provider runs with
   `foldersFromFilesStructure: true`, so each subdirectory becomes a Grafana folder.
3. **Fixed datasource uid.** The provisioned Prometheus datasource declares an explicit
   `uid: prometheus` (OpenObserve: `uid: openobserve`). **Every dashboard references
   `"uid": "prometheus"`** so panels bind deterministically instead of relying on
   Grafana's name-fallback shim. This is the single most common reason imported
   dashboards render empty — every import must be rewritten to this uid.
4. **No dead panels.** Imported dashboards are trimmed of panels whose metrics this
   stack does not collect (recorded below).

## Folder taxonomy

| Folder | Purpose |
|---|---|
| `Instances` | Per-instance overviews — "what is happening on this box" (custom). |
| `Infrastructure` | Host + container deep dives (node_exporter, cAdvisor). |
| `Platform` | The monitoring stack itself (Prometheus, Alertmanager, Blackbox). |
| `Kubernetes` | k0s node / cluster state (cAdvisor + kube-state-metrics). |
| `Logging` | syslog-ng pipeline health (logging cluster only). |
| `Netdata` | Real-time host + container views from the scraped `netdata_*` series. |

## Dashboard inventory

### Custom-authored (bound to `uid: prometheus`)

| File | Title | What it answers |
|---|---|---|
| `Instances/instance-overview.json` | Instance Overview | Flagship. `$instance` variable; up/uptime, CPU busy %, load 1/5/15, mem/swap used %, per-mount disk used %, disk IO, network RX/TX, filesystem inodes, running containers, failed systemd units. |
| `Instances/processes-systemd.json` | Processes & systemd | `$instance` variable; top processes by CPU and RSS (`namedprocess_namegroup_*`), open FDs, systemd unit states (`node_systemd_unit_state`). |
| `Logging/logging-pipeline.json` | Logging Pipeline | (logging cluster) syslog-ng ingested/dropped/queued from the textfile collector, per-client last-received freshness + file size from filestat_exporter. |
| `Netdata/netdata-fleet.json` | Netdata — Fleet | `$instance` (multi); per-second CPU busy %, RAM used %, load1, root-FS used %, net rx/tx across every VM from the scraped `netdata_*` series. |
| `Netdata/netdata-instance.json` | Netdata — Instance | `$instance`; realtime deep dive — CPU by mode (stacked), memory breakdown, per-mount disk, disk I/O, per-interface net, load. |
| `Netdata/netdata-containers.json` | Netdata — Containers | `$instance` + `$container`; per-container CPU/mem/net/PIDs/throttling keyed on netdata's resolved **`cgroup_name`** + **`image`** labels — never a container id. |

The two original starter dashboards are retained (moved to `Instances/`) with their
datasource uid corrected.

**Netdata series names (verified live, netdata v2.10.3).** The `netdata_*` metric names are
version-dependent — panels were built against a live `curl :19999/api/v1/allmetrics?format=prometheus`
dump (mirroring the `syslogng_*` caution below). Key contexts: `netdata_system_cpu_percentage_average`
(`dimension`), `netdata_system_ram_MiB_average` (`dimension` free/used/cached/buffers),
`netdata_system_load_load_average`, `netdata_disk_space_GiB_average` (`family`=mount),
`netdata_disk_io_KiB_persec_average` (`device`), `netdata_net_net_kilobits_persec_average` (`family`=iface),
and the cgroup family `netdata_cgroup_{cpu_percentage,mem_usage_MiB,net_net_kilobits_persec,pids_current_pids,throttled_percentage}_average`,
all carrying `cgroup_name` + `image`. Note: **used-% panels wrap the numerator in the same
`sum by (...)` as the denominator** — netdata's per-dimension series carry extra `chart`/`family`/`dimension`
labels, so `metric{dimension="used"} / sum by (instance)(metric)` matches nothing; aggregate both sides.

### Identity: never key a panel on a container id

Panels identify workloads by the friendliest available label, never a raw cgroup path or
container hash. Priority: **compose service / k8s `namespace`+`pod`+`container` / process `groupname`
/ netdata `cgroup_name` > `name` > `id`.** Concretely:
- `Netdata/netdata-containers.json` uses netdata's resolved `cgroup_name` (`stack-grafana-1`) + `image`.
- `Instances/cadvisor-k8s.json` groups `by (namespace, pod, container)` with `container!="",container!="POD"`
  (the cAdvisor `name` label is **empty** on the k0s containerd node — the original `by (name)` showed nothing).
- `Kubernetes/kubernetes.json` (community import) already groups `by (pod, container)` with readable
  legends; its `id="/"` selectors are legitimate node-root-cgroup aggregates, left intact.
- `Instances/processes-systemd.json` keys processes on `groupname`; docker `Infrastructure/cadvisor.json`
  uses the friendly Docker container `name`.

### Community imports (grafana.com — datasource re-pointed to `uid: prometheus`)

| File | Title | grafana.com ID | Folder |
|---|---|---|---|
| `Infrastructure/node-exporter-full.json` | Node Exporter Full | [1860](https://grafana.com/grafana/dashboards/1860-node-exporter-full/) | Infrastructure |
| `Infrastructure/cadvisor.json` | Cadvisor exporter | [14282](https://grafana.com/grafana/dashboards/14282-cadvisor-exporter/) | Infrastructure |
| `Platform/blackbox.json` | Blackbox Exporter | [7587](https://grafana.com/grafana/dashboards/7587-prometheus-blackbox-exporter/) (fallback [14523](https://grafana.com/grafana/dashboards/14523-blackbox-exporter-node/)) | Platform |
| `Platform/prometheus.json` | Prometheus Overview | [3662](https://grafana.com/grafana/dashboards/3662-prometheus-2-0-overview/) (fallback [19105](https://grafana.com/grafana/dashboards/19105-prometheus/)) | Platform |
| `Platform/alertmanager.json` | Alertmanager | [9578](https://grafana.com/grafana/dashboards/9578-alertmanager/) | Platform |
| `Kubernetes/kubernetes.json` | Kubernetes (cAdvisor + KSM) | [15398](https://grafana.com/grafana/dashboards/15398-kubernetes-monitor/) (fallback [315](https://grafana.com/grafana/dashboards/315-kubernetes-cluster-monitoring-via-prometheus/)) | Kubernetes |

**Netdata:** each VM still exposes its full self-hosted UI on `:19999`, but the scraped
`netdata_*` series are now also surfaced in Grafana (the `Netdata/` folder above) so a single
pane covers the whole fleet — including the readable per-container view. See `specs/dashboard-update.md`.

Import adaptation recipe (applied programmatically, see `scripts/`/notes below):
1. Delete `__inputs` and `__requires`.
2. Rewrite every `datasource` reference (panels, targets, templating) to
   `{ "type": "prometheus", "uid": "prometheus" }`; drop `${DS_*}` datasource template vars.
3. Give each a stable top-level `uid` (e.g. `node-exporter-full`).
4. Trim panels referencing metrics absent from this stack.

## Provisioning mechanics (OpenTofu)

`main.tf` (monitoring cluster):

```hcl
locals {
  grafana_dashboard_dir   = "${path.module}/cloud-init/grafana/dashboards"
  grafana_dashboard_files = fileset(local.grafana_dashboard_dir, "**/*.json")
  grafana_dashboards = [for f in local.grafana_dashboard_files : {
    name    = f  # e.g. "Infrastructure/node-exporter-full.json"
    content = file("${local.grafana_dashboard_dir}/${f}")
  }]
}
```

`cloud-init/server.yaml.tftpl` (write_files), gzip+base64 to keep large JSON compact and
cloud-init valid:

```yaml
%{ for d in grafana_dashboards ~}
  - path: /opt/stack/grafana/dashboards/${d.name}
    permissions: '0644'
    encoding: gz+b64
    content: ${base64gzip(d.content)}
%{ endfor ~}
```

`cloud-init/grafana/provisioning/dashboards/dashboards.yaml`:
`options.path: /var/lib/grafana/dashboards`, `foldersFromFilesStructure: true`.

The compose stack already bind-mounts `/opt/stack/grafana/dashboards` →
`/var/lib/grafana/dashboards:ro`, so no compose change is needed.

## Per-cluster coverage

- **centralized_monitoring** — full set. Its Prometheus already scrapes both VMs
  (server + k0s) across OS and k8s layers.
- **centralized_logging** — the logging cluster self-monitors via its **own** Prometheus
  + Grafana on the `docker` VM. That Prometheus scrapes all three VMs (central/docker/k0s
  exporters — jobs `logging-*`, mirroring `cloud-init/prometheus/logging-scrape.yml`),
  with central/k0s IPs injected at render time and the docker VM's own IP substituted at
  boot via a `__SELF_IP__` sed (host exporters bind `0.0.0.0`, off the compose network).
  Grafana provisioning mirrors the monitoring cluster and ships the shared dashboard JSONs
  plus `Logging/logging-pipeline.json`. Kept per-cluster self-contained (no cross-cluster
  IP wiring) to honor the repo's per-folder vendoring; the `logging-scrape.yml` reference
  remains for optionally pulling the logging cluster into the monitoring Prometheus too.

  The `logging-pipeline.json` panels use the conventional `syslogng_*` (node_exporter
  textfile collector) and `file_stat_*` (filestat_exporter) series names; exact names
  track the installed syslog-ng / filestat_exporter versions and may need adjustment.

## Testing

Two-layer, mirroring the existing split:

- **Hermetic** (`tests/tofu/sizing_and_render.tftest.hcl`, `command = plan`, mocked
  provider): assert the rendered server cloud-init splices the dashboard files (the
  flagship + at least one import path) and that the datasource render declares
  `uid: prometheus`; the existing `can(yamldecode(...))` assertion keeps the gz+b64
  loop valid YAML. Closes the prior gap where no test covered dashboards.
- **Live** (`tests/testinfra/test_e2e_scrape.py`): `test_grafana_dashboards_provisioned`
  queries `GET /api/search?type=dash-db` and asserts the expected dashboard titles/uids
  are present; a representative `GET /api/dashboards/uid/instance-overview` returns 200.
  Panel-level data assertions are out of scope (flaky); `just open` covers visual
  confirmation.
- **JSON validity:** every dashboard file passes `jq empty`.

Validation commands: `just check <cluster>` (hermetic), `just up <cluster>` +
`just verify <cluster>` (live), `just open <cluster>` (visual).
