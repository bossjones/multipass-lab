# Spec: Fleet-wide Netdata from `clusters/_shared`, ingested into Prometheus

> **Status:** design/spec only (no code yet). Implement with `/agent-harness:build specs/shared-netdata.md`.
> Netdata source checkout is available locally at `~/dev/netdata/netdata` — use it for lookups.
> Reference links are collected at the bottom.

---

## Context — why this change

The lab wants **Netdata on every VM** (its zero-config auto-discovery is the draw), with those
metrics **pulled into the `centralized_monitoring` Prometheus** so the existing Grafana + alerting
stack covers the whole fleet.

This is **not greenfield**: Netdata is **already integrated for the two `centralized_monitoring`
VMs** — a `netdata` Prometheus scrape job, an install runcmd on both VMs, **three** Grafana
dashboards under `cloud-init/grafana/dashboards/Netdata/`, a flag-aware `prometheus_cli.py` health
check (`FLAG_JOBS` already maps `enable_netdata → netdata`), and `tests/testinfra/test_netdata.py`.
So the real work is to **generalize that per-cluster wiring into one shared, templated cloud-init
snippet** in `clusters/_shared/cloud-init/`, turn it **on fleet-wide**, and **extend Prometheus to
scrape every fleet VM's Netdata** (the current cross-cluster scrape loop only emits plain `:9100`
node-exporter jobs — it can't reach Netdata on `:19999`).

**Design decisions:**
1. `enable_netdata` defaults **ON** fleet-wide (a plain `just up <cluster>` installs Netdata on every VM).
2. Prometheus export source stays **`average`** (matches the 3 existing dashboards + health check; gauges in real units, e.g. `netdata_system_cpu_percentage_average`). **Do not** switch to `as-collected` (would break the dashboards).
3. **eBPF** is a **separate opt-in flag `enable_netdata_ebpf`, default OFF** (heaviest collector; arm64-stable availability is uncertain). Base install still enables all standard collectors.
4. **SNMP / UniFi** is **documented as a future add-on**, not implemented now.

**Intended outcome:** internal-only, **no Netdata Cloud**. Every VM runs a Netdata agent tuned for
maximum host coverage; `http://<vm-ip>:19999` serves the live dashboard + Prometheus endpoint;
Prometheus scrapes them all under one `job="netdata"`; Grafana dashboards and a new Netdata alert
group light up automatically; `just refresh-cross-cluster` hot-rewires targets with no VM recreate.

---

## Objective

A single shared, templated installer snippet (`clusters/_shared/cloud-init/install-netdata.sh.tftpl`)
that every cluster renders per-VM, gated by `enable_netdata` (default true) and `enable_netdata_ebpf`
(default false), plus the Prometheus/Grafana/alert/Justfile changes needed to ingest and visualize
the whole fleet — and a debugging runbook for fast live iteration.

---

## Problem Statement

- Netdata's install + tuning currently lives **inline and duplicated** in
  `centralized_monitoring/cloud-init/{server,k0s-client}.yaml.tftpl`. It is not reusable by the
  other five clusters.
- The cross-cluster Prometheus scrape mechanism (`extra_scrape_targets` loop in
  `prometheus.yml.tftpl`) emits **plain `- targets: ["${ip}:${port}"]`** jobs with **no
  `metrics_path`/`params`** — it scrapes `/metrics`, which Netdata does not serve in Prometheus
  format. It cannot reach Netdata's `/api/v1/allmetrics?format=prometheus` on `:19999`.
- There are **no Netdata-specific alert rules** (only generic `TargetDown` / `BlackboxProbeFailed`).
- "Maximum stats" tuning (host labels, all collectors, plugin conflict avoidance, optional eBPF) is
  not standardized.

## Solution Approach

Mirror the repo's **templated shared-snippet** idiom (exactly how
`clusters/_shared/cloud-init/otel-agent-config.yaml.tftpl` and `issue-cert.sh.tftpl` are rendered
per-VM by each cluster's `main.tf`, then dropped via a gated `%{ if ... ~}` `write_files` +
`runcmd` block). The closest structural precedent for a self-contained installer is the currently
**unwired** `clusters/_shared/cloud-init/install-node-exporter.sh` — copy its shape but make it a
`.tftpl` so we can inject per-VM host labels + the eBPF toggle.

Keep **one** Prometheus `job_name: netdata` (so the dashboards, `FLAG_JOBS`, and testinfra keep
working) and **fold cross-cluster targets into it** via a new `netdata_scrape_targets` variable
populated by `just up-connected` / `refresh-cross-cluster` — the same discover-IPs → write
`.cross-cluster.auto.tfvars.json` → outputs-only `tofu apply` → scp `prometheus.yml` → `docker
compose restart prometheus` hot-push already used for `extra_scrape_targets`.

---

## Relevant Files

**Read/mirror (existing patterns):**
- `clusters/_shared/cloud-init/install-node-exporter.sh` — structural template for a self-contained arch-aware installer + systemd unit (currently unwired; do **not** delete — reference).
- `clusters/_shared/cloud-init/otel-agent-config.yaml.tftpl`, `issue-cert.sh.tftpl` — the **templated** shared-snippet idiom (per-VM params, `$${...}` shell escaping inside a `.tftpl`).
- `clusters/centralized_pki/{main.tf,variables.tf,cloud-init/ca.yaml.tftpl}` — reference consumer: how a shared snippet is rendered in a `local`, threaded into each VM's `local_file` content map, gated with `%{ if var != "" ~}` `write_files`+`runcmd`, and hot-pushed via a `count`-gated `local_file`.
- `clusters/centralized_monitoring/cloud-init/{server,k0s-client}.yaml.tftpl` — the **existing inline** Netdata install runcmd (`get.netdata.cloud/kickstart.sh ... --non-interactive --stable-channel --disable-telemetry --no-updates --dont-wait`, `DO_NOT_TRACK=1`, then `printf '...[plugins]\n\tstatsd = no\n\totel = no\n' >> /etc/netdata/netdata.conf`) — **replace** with the shared snippet.
- `clusters/centralized_monitoring/cloud-init/prometheus/prometheus.yml.tftpl` — the `%{ if enable_netdata ~}` `netdata` job (lines 43-59) + the `extra_scrape_targets` loop (lines 158-163).
- `clusters/centralized_monitoring/cloud-init/prometheus/alert.rules.yml` — add a `netdata` group.
- `clusters/centralized_monitoring/cloud-init/grafana/dashboards/Netdata/*.json` — existing 3 dashboards (query `_average` gauges, `$instance` = `label_values(netdata_system_uptime_seconds_average, instance)`); they auto-pick up new instances.
- `clusters/centralized_monitoring/cloud-init/docker/compose.yaml.tftpl` — the `%{ if enable_netdata ~} extra_hosts: host.docker.internal:host-gateway` block (keep; server Netdata is host-installed, reached via the docker host gateway).
- `clusters/centralized_monitoring/scripts/prometheus_cli.py` — `FLAG_JOBS` (`enable_netdata → netdata`) + flag-aware `check`.
- `Justfile` (root) — `up-connected` (IP discovery ~lines 246-294) and `refresh-cross-cluster` (~lines 467-537); both build a `targets` list at `port:9100` and hot-push `prometheus.yml`.
- `specs/cross-cluster.md` — snippet inventory table to update.

### New Files
- `clusters/_shared/cloud-init/install-netdata.sh.tftpl` — **the shared installer** (templated per-VM). Params: `host_labels` (map: cluster, role, environment), `enable_ebpf` (bool). Idempotent kickstart install + max-stats `netdata.conf` + host labels + plugin-conflict avoidance + docker-group add + optional eBPF + restart.
- Per-cluster hermetic tests: extend each cluster's `tests/tofu/*.tftest.hcl` to assert the Netdata snippet renders when on and is absent when `enable_netdata=false`.

---

## Implementation Phases

### Phase 1: Foundation — the shared snippet + max-stats config
Create `install-netdata.sh.tftpl` and get it installing a well-tuned Netdata on **one** VM
(`centralized_pki-ca` is a good first target — small, docker-based). Prove the endpoint serves
`average` Prometheus metrics and host labels appear in `netdata_info`.

### Phase 2: Core — fleet-wide wiring + Prometheus ingestion
Wire the snippet into all six clusters (default on), replace the monitoring cluster's inline
install, add `netdata_scrape_targets` + the folded-in scrape loop, and teach
`up-connected`/`refresh-cross-cluster` to discover `:19999` targets.

### Phase 3: Integration & Polish — alerts, dashboards, checks, tests, docs
Add the Netdata alert group, confirm dashboards populate for the fleet, extend the health check +
testinfra, add hermetic tests, and write the debugging runbook into the spec.

---

## Step by Step Tasks

IMPORTANT: Execute every step in order.

### 1. Author `clusters/_shared/cloud-init/install-netdata.sh.tftpl`
- Header comment matching other shared files (`# Managed by OpenTofu — SHARED cross-cluster snippet`) **and** the `.tftpl` escaping note (shell `$` must be doubled as `$${...}`; injected vars use single `${...}`).
- **Install (idempotent, DNS-race-safe):** guard on `command -v netdata`. Before the kickstart `curl`, add a **resolver-ready gate + retry** (repo gotcha — cloud-init `runcmd` is `/bin/sh` with no `set -e`; a DNS warm-up race silently fails installs):
  ```sh
  until getent hosts get.netdata.cloud >/dev/null 2>&1; do sleep 2; done
  for i in 1 2 3 4 5; do
    curl -sSLf https://get.netdata.cloud/kickstart.sh -o /tmp/netdata-kickstart.sh && break; sleep 5
  done
  DO_NOT_TRACK=1 sh /tmp/netdata-kickstart.sh \
    --non-interactive --stable-channel --disable-telemetry --no-updates --dont-wait
  ```
  - `--non-interactive` (automation), `--stable-channel` (reproducible), `--disable-telemetry` + `DO_NOT_TRACK=1` (no anonymous stats). **No `--claim-*` flags → stays fully local, no Netdata Cloud account.** `--no-updates` disables the daily auto-update cron for deterministic IaC. `--dont-wait` returns immediately.
- **Max-stats `netdata.conf`** — write the tuning sections (keep 1s resolution + default 5-tier dbengine retention; `go.d default_run: yes` already runs every auto-detecting module):
  ```ini
  [db]
      update every = 1
  [plugins]
      statsd = no        # avoid :8125 conflict with monitoring's statsd_exporter
      otel   = no        # avoid conflict with the OTel collector
      ebpf   = ${enable_ebpf ? "yes" : "no"}
  [host labels]
      cluster     = ${host_labels.cluster}
      role        = ${host_labels.role}
      environment = lab
  ```
  (Host labels ride on `netdata_info{...} 1` and enrich Grafana via `* on(instance) group_left(...)`.)
- **Docker autodiscovery:** `getent group docker >/dev/null 2>&1 && usermod -aG docker netdata || true` so go.d's docker service-discovery (enabled by default) can read `/var/run/docker.sock`.
- `systemctl restart netdata` at the end. Whole script must be **re-runnable** (edit-in-place iteration).

### 2. Add the two feature-flag variables to every cluster
- In each cluster's `variables.tf`: `enable_netdata` (bool, **default true**) and `enable_netdata_ebpf` (bool, **default false**). `centralized_monitoring` already has `enable_netdata` — keep it, add the ebpf flag.
- Add both to each cluster's `local.flags` map (so `merge()` threads them into every `templatefile()` and they appear in `local.enabled_flags` for testinfra).

### 3. Render the shared snippet per-VM in each cluster's `main.tf`
- For each VM role, add a `local` rendering the snippet with that VM's labels:
  ```hcl
  netdata_installer_<role> = var.enable_netdata ? templatefile(
    "${path.module}/../_shared/cloud-init/install-netdata.sh.tftpl", {
      host_labels = { cluster = var.name_prefix, role = "<role>", environment = "lab" }
      enable_ebpf = var.enable_netdata_ebpf
  }) : ""
  ```
- Thread each into that VM's `local_file` content map (alongside the existing `otel_agent_conf`, etc.).

### 4. Add the gated `write_files` + `runcmd` blocks to every VM cloud-config `.tftpl`
- Mirror the docker-tools idiom. In each `<role>.yaml.tftpl` (13 cloud-configs across 6 clusters):
  ```
  %{ if enable_netdata ~}
    - path: /usr/local/sbin/install-netdata.sh
      permissions: '0755'
      content: |
        ${indent(6, netdata_installer)}
  %{ endif ~}
  ```
  and in `runcmd`:
  ```
  %{ if enable_netdata ~}
    - /usr/local/sbin/install-netdata.sh || true
  %{ endif ~}
  ```
- **In `centralized_monitoring/cloud-init/{server,k0s-client}.yaml.tftpl`: remove the existing inline kickstart runcmd** (now handled by the shared snippet) to avoid double-install. Keep the compose `extra_hosts` block.

### 5. Add `netdata_scrape_targets` and fold cross-cluster targets into the `netdata` job
- `centralized_monitoring/variables.tf`: new variable
  ```hcl
  variable "netdata_scrape_targets" {
    type    = list(object({ name = string, ip = string }))
    default = []
  }
  ```
- `main.tf`: pass `netdata_scrape_targets = var.netdata_scrape_targets` into the `prometheus.yml.tftpl` render.
- `prometheus.yml.tftpl`: **inside** the existing `%{ if enable_netdata ~}` netdata job (after the two in-cluster static_configs, still under `job_name: netdata`, `honor_labels: true`):
  ```
  %{ for t in netdata_scrape_targets ~}
        - targets: ["${t.ip}:19999"]
          labels: { instance: "${t.name}" }
  %{ endfor ~}
  ```
  Keeping one `job="netdata"` means the dashboards' `$instance` picker, `FLAG_JOBS`, and testinfra all keep working; each fleet VM shows up with a friendly hostname `instance` label.

### 6. Teach `up-connected` + `refresh-cross-cluster` to discover Netdata targets
- In both discovery loops (root `Justfile`), alongside the existing `port:9100` accumulation, build a parallel `netdata_targets` list `[{name, ip}]` from every consumer VM's `tofu output -json hosts` **and** the hub VMs (`centralized_logging`, `centralized_dns`), **excluding** `centralized_monitoring`'s own two VMs (already static in the job).
- Add `netdata_scrape_targets: <list>` to the `jq` object written to `clusters/centralized_monitoring/.cross-cluster.auto.tfvars.json`. The existing outputs-only `tofu apply` → scp `prometheus.yml` → `docker compose restart prometheus` hot-push then wires it live with **no VM recreate**.

### 7. Add the Netdata alert group to `alert.rules.yml`
- New `- name: netdata` group with `average`-source expressions. **Metric names verified against a
  live agent (v2.10.3)** — note the IEC units (`MiB`/`GiB`, not `MB`/`GB`):
  - **NetdataHostHighCPU** — `100 - avg by (instance) (netdata_system_cpu_percentage_average{dimension="idle"}) > 85` for 10m (warning).
  - **NetdataHostLowMemory** — free RAM ratio from `netdata_system_ram_MiB_average` (`dimension="free"` / total) `< 0.10` for 10m (warning).
  - **NetdataHostRootDiskLow** — `netdata_disk_space_GiB_average{family="/",dimension="avail"} < 3` for 10m (warning).
  - **NetdataHostRootDiskWillFill** — `predict_linear(netdata_disk_space_GiB_average{family="/",dimension="avail"}[1h], 24*3600) < 0` for 15m (warning).
  - *(Load, if wanted, is `netdata_system_load_load_average{dimension="load15"}` — a single metric with a `load15` dimension, not `..._load15_average`. Agent-down is already covered generically by `TargetDown` on `job="netdata"`.)*

### 8. (Optional) Strengthen the health check
- `prometheus_cli.py`: `check` already asserts `job netdata` has live, non-down targets (via `FLAG_JOBS`). Optionally assert the **target count** ≥ number of enabled fleet VMs so a silently-missing node is caught.

### 9. Hermetic tests (`just check`)
- Add per-cluster `tests/tofu/*.tftest.hcl` runs asserting: with `enable_netdata=true` the rendered cloud-config contains `/usr/local/sbin/install-netdata.sh`; with `enable_netdata=false` it does not; and the config carries the `[host labels]` block.
- **Gotcha:** because `enable_netdata` now defaults **true**, and `just check`/`tofu test` auto-loads `*.auto.tfvars(.json)`, a leftover `.cross-cluster.auto.tfvars.json` could inject `netdata_scrape_targets` during hermetic runs. Pin `enable_netdata` / `netdata_scrape_targets` explicitly in each test's **file-level** `variables {}` block (outranks auto-loaded tfvars).

### 10. Live testinfra (`just verify` / `verify-connected`)
- Generalize the assertions in `centralized_monitoring/tests/testinfra/test_netdata.py` (service running, `:19999` listening, `/api/v1/allmetrics?format=prometheus` returns `netdata_*`) into a check reusable by every cluster's suite (or add a light per-cluster netdata assertion). Add a `verify-connected` assertion that `up{job="netdata"}` is `1` for every fleet VM.

### 11. Docs
- This spec (`specs/shared-netdata.md`).
- Update the shared-snippet inventory table in `specs/cross-cluster.md` to list `install-netdata.sh.tftpl`.
- Add an `enable_netdata` / `enable_netdata_ebpf` row to any per-cluster feature-flag reference (e.g. `clusters/centralized_logging/docs/feature-flags.md`).

### 12. Validate end-to-end (see Validation Commands + Debugging)
- `just check` each touched cluster (hermetic), then a live `just recreate centralized_pki` (cloud-init changed → **recreate, not up**), verify the endpoint, then `just up-connected` for the fleet and confirm Prometheus scrapes all Netdata targets.

---

## Debugging & fast live-iteration runbook

**Discover metric names before writing PromQL/alerts** — open the Netdata UI or dump the endpoint:
- Netdata's own dashboard (shows every collected chart): `http://<vm-ip>:19999`
- Prometheus endpoint (the live source of truth for metric names/labels):
  ```sh
  curl -s 'http://<vm-ip>:19999/api/v1/allmetrics?format=prometheus&help=yes&types=yes&source=as-collected' | head -100
  curl -s 'http://<vm-ip>:19999/api/v1/allmetrics?format=prometheus' | grep '_average' | head   # what the dashboards see
  curl -s http://<vm-ip>:19999/api/v1/info | jq '{version, labels, collectors: .collectors}'
  ```
  Resolve `<vm-ip>` the repo way:
  ```sh
  IP=$(tofu -chdir=clusters/<cluster> output -json hosts | jq -r '.<role>.ipv4')
  ```

**Is the agent healthy on the VM?** (SSH in — `multipass exec` doesn't route here; use the IP):
```sh
ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 ubuntu@$IP
sudo systemctl status netdata --no-pager
sudo journalctl -u netdata -b --no-pager | tail -50
sudo netdatacli dumpconfig | less              # effective merged config
sudo netdata -W buildinfo | grep -i ebpf        # confirm eBPF plugin availability on arm64
```

**Iterate on cloud-init WITHOUT a full `just recreate`** (repo idiom — far faster):
1. SSH in, edit `/usr/local/sbin/install-netdata.sh` or `/etc/netdata/netdata.conf` directly.
2. `sudo /usr/local/sbin/install-netdata.sh` (it's idempotent) **or** `sudo systemctl restart netdata`.
3. Re-`curl` the endpoint. Once happy, **fold the fix back into `install-netdata.sh.tftpl`**.
> Editing the `.tftpl` then `just up` silently reuses the stale VM — cloud-init changes need
> `just recreate <cluster>`. Prefer the SSH-edit loop above during development.

**Debug a specific go.d collector:**
```sh
sudo su -s /bin/bash netdata -c '/usr/libexec/netdata/plugins.d/go.d.plugin -d -m <module>'
```

**Prometheus side (hot, no recreate):**
```sh
just prometheus-targets centralized_monitoring          # per-target up/down
just prometheus-query   centralized_monitoring 'up{job="netdata"}'
just refresh-cross-cluster                               # re-discover IPs + hot-push prometheus.yml
open http://<mon-ip>:9090/targets                        # scrape health in the UI
```

**Grafana:** `just open centralized_monitoring` → Netdata folder; the fleet dashboard's `$instance`
picker should list every VM. `just verify-api centralized_monitoring` runs `prometheus_cli check`
(asserts `job=netdata` is up).

---

## Testing Strategy

- **Hermetic (`just check`, `mock_provider` + `command = plan`):** assert the Netdata snippet renders
  on/off with the flag and carries `[host labels]`; assert `prometheus.yml` renders the
  `netdata_scrape_targets` loop. No VMs. Guard against `*.auto.tfvars.json` poisoning (Step 9).
- **Live (`just verify` / `verify-connected`, testinfra over SSH):** Netdata service active, `:19999`
  serving Prometheus format with `netdata_*`, host labels present in `/api/v1/info`; and from the
  monitoring hub, `up{job="netdata"} == 1` for every fleet VM.
- **Edge cases:** DNS warm-up race on first boot (mitigated by the resolver gate + retry, Step 1);
  eBPF plugin missing on arm64 stable (flag default off; `netdata -W buildinfo` check); StatsD `:8125`
  conflict with `statsd_exporter` (plugin disabled in config); a fleet VM absent from
  `netdata_scrape_targets` after a partial `up-connected` (optional count assertion, Step 8).

## Acceptance Criteria

- `clusters/_shared/cloud-init/install-netdata.sh.tftpl` exists and is rendered by all six clusters.
- A plain `just up <cluster>` installs Netdata on every VM (default on); `http://<vm-ip>:19999` serves
  the dashboard and `/api/v1/allmetrics?format=prometheus` returns `netdata_*` gauges.
- `netdata_info` on each VM carries `cluster` + `role` + `environment=lab` labels.
- After `just up-connected`, `centralized_monitoring` Prometheus shows one `job="netdata"` with a
  live target per fleet VM (friendly `instance` labels), and `up{job="netdata"}==1` for all.
- The 3 existing Grafana dashboards populate for the whole fleet with no query changes.
- A `netdata` alert group is loaded and evaluates without error.
- `enable_netdata_ebpf=true` on a VM adds eBPF metrics; default off elsewhere.
- `just check` (all touched clusters), `just verify-connected`, and `just prometheus-check
  centralized_monitoring` pass. SNMP/UniFi appears only as a documented future section.

## Validation Commands

- `just check centralized_pki` (and each touched cluster) — hermetic tofu fmt/validate/test.
- `uvx ruff check clusters/centralized_monitoring/scripts/prometheus_cli.py` — lint (if touched).
- `just recreate centralized_pki` then
  `curl -s "http://$(tofu -chdir=clusters/centralized_pki output -json hosts | jq -r '.ca.ipv4'):19999/api/v1/allmetrics?format=prometheus" | grep -c netdata_` — live endpoint serves metrics (nonzero).
- `just up-connected` then
  `just prometheus-query centralized_monitoring 'up{job="netdata"}'` — every fleet VM `== 1`.
- `just verify-connected` — live cross-cluster e2e incl. Netdata scrape health.
- `just prometheus-check centralized_monitoring` — flag-aware check asserts `job=netdata` healthy.

## Notes

- **No new host/uv dependencies.** Netdata installs via the official kickstart script inside each VM;
  arch (arm64) is auto-detected. Everything else reuses existing tofu/Justfile/testinfra machinery.
- **Boot cost:** default-on adds the kickstart install (~30-60s) to every VM's first boot; the
  resolver-gate + retry (Step 1) hardens it against the documented DNS warm-up race.
- **`average` vs `as-collected`:** the *scraper's* URL param picks the source, not the agent — the
  existing job uses `format=prometheus` with no `source` ⇒ `average`. Keeping it means zero dashboard
  rework. `help=yes&types=yes` are for humans eyeballing the raw endpoint only; leave them **off** in
  the scrape job (they bloat the payload and repeat HELP/TYPE per metric).

---

## Reference links (for lookups during implementation)

- Netdata source checkout (local): `~/dev/netdata/netdata` — key paths:
  - Prometheus exporter doc + emitter: `src/exporting/prometheus/README.md`, `src/exporting/prometheus/prometheus.c`, `src/exporting/read_config.c`
  - DB/retention defaults: `src/daemon/config/netdata-conf-db.c`; sizing: `docs/netdata-agent/sizing-netdata-agents/`
  - go.d master switch: `src/go/plugin/go.d/config/go.d.conf` (`default_run: yes`)
  - Service discovery: `src/go/plugin/go.d/config/go.d/sd/{net_listeners,docker,snmp}.conf`
  - SNMP UniFi profile: `src/go/plugin/go.d/config/go.d/snmp.profiles/default/ubiquiti-unifi.yaml`
  - Install/kickstart flags: `packaging/installer/methods/kickstart.md`
- Repo: https://github.com/netdata/netdata — Collectors: https://learn.netdata.cloud/docs/collecting-metrics
- Prometheus/Grafana stack guide: https://www.netdata.cloud/blog/netdata-prometheus-grafana-stack/
- SNMP devices: https://learn.netdata.cloud/docs/network-performance-monitoring/device-metrics/integrations/snmp-devices
- SNMP default profiles dir: https://github.com/netdata/netdata/tree/master/src/go/plugin/go.d/config/go.d/snmp.profiles/default
- UniFi profile (raw): https://github.com/netdata/netdata/blob/master/src/go/plugin/go.d/config/go.d/snmp.profiles/default/ubiquiti-unifi.yaml
- SNMP SD config: https://github.com/netdata/netdata/blob/master/src/go/plugin/go.d/config/go.d/sd/snmp.conf
- Grafana Netdata data-source plugin: https://learn.netdata.cloud/docs/dashboards-and-charts/grafana-plugin — blog: https://www.netdata.cloud/blog/introducing-netdata-source-plugin-for-grafana/
- Netdata Charts: https://learn.netdata.cloud/docs/dashboards-and-charts/charts
- Grafana dashboards (import candidates for `average` source):
  - 7107 Netdata: https://grafana.com/grafana/dashboards/7107-netdata/
  - 12279 Netdata & Prometheus: https://grafana.com/grafana/dashboards/12279-netdata/
  - 10922 Netdata Monitoring: https://grafana.com/grafana/dashboards/10922-netdata-monitoring/
  - 4562 Netdata Server Metrics: https://grafana.com/grafana/dashboards/4562-netdata-server-metrics/
  - 12555 Netdata: https://grafana.com/grafana/dashboards/12555-netdata/
  - 13746 Disks / 13748 CPU / 13761 Containers / 13743 Users stats
  - 12183 System Dashboard (Telegraf + Netdata): https://grafana.com/grafana/dashboards/12183-system-dashboard-telegraf-netdata/
  - search: https://grafana.com/grafana/dashboards/?search=netdata

---

## Future add-on (out of scope now): SNMP / UniFi

`centralized_unifi` exists. Netdata's go.d `snmp` collector auto-selects the
`ubiquiti-unifi.yaml` profile by `sysObjectID` (Ubiquiti enterprise OID `1.3.6.1.4.1.41112`).
For a single device you don't need service discovery — add one static `snmp` job (device IP +
SNMP community/v3 creds, referenced via `${env:VAR}`/`${file:/path}`, never plaintext) under
go.d and the profile applies automatically (IF-MIB interface counters + `unifiRadioTable`
per-radio RX/TX + channel utilization). SD (`sd/snmp.conf`, disabled by default) is only needed
to sweep whole subnets. Wire this as a follow-up `enable_netdata_snmp` flag + a templated go.d
`snmp.conf` drop-in in the shared snippet.
