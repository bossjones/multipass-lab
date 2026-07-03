# Plan: DNS Dashboards (AdGuard Home + Unbound) for Grafana & OpenObserve

Status: **planned** · Task type: **feature** · Complexity: **medium**
Depends on: `clusters/centralized_dns` (exporters) + `clusters/centralized_monitoring` (Grafana/Prometheus/OpenObserve)
Companion specs: `specs/dashboards.md` (Grafana drop-a-file), `specs/openobserve-dashboards.md` (OO drop-a-file), `specs/centralized_dns.md`, `specs/cross-cluster.md`

## Task Description

Add first-class observability dashboards for the `centralized_dns` cluster's two DNS
services — **AdGuard Home** (ad/tracker-blocking front-end, `adguard-exporter` on `:9618`)
and **Unbound** (recursive DNSSEC resolver, `unbound_exporter` on `:9167`) — to the
`centralized_monitoring` stack. Four dashboards total:

- **Grafana** (`uid: prometheus` datasource): `DNS/adguard-home.json`, `DNS/unbound.json`.
- **OpenObserve** (PromQL over the `metrics` stream): `DNS/adguard-home.json`, `DNS/unbound.json`.

Design inspiration (metric shape + panel layout) from the community dashboards the user cited:
- AdGuard: grafana.com **20799** (AdGuard Home Exporter — matches the `henrywhitaker3/adguard-exporter`
  we deploy), plus **24520** (multi-instance), **13330**, **23579** for panel ideas.
- Unbound: grafana.com **18077** and [`ar51an/unbound-dashboard`](https://github.com/ar51an/unbound-dashboard)
  (both target the `letsencrypt/unbound_exporter` metric names we deploy).

**None of the community dashboards import verbatim** — they must be re-authored against this
stack's fixed datasource uid, job labels, and the exact metric names our two exporters emit
(same discipline `specs/dashboards.md` §Import-adaptation and `specs/openobserve-dashboards.md`
already establish for every other imported board).

## Objective

After this work, `just open centralized_monitoring` (Grafana) and the OpenObserve UI both
show a DNS folder with an AdGuard Home board and an Unbound board that populate with live
data once the DNS exporters are being scraped (i.e. after `just up-connected`). Adding each
board is a **single JSON drop** into the existing sweep directories — no `main.tf` edits.
`just check centralized_monitoring` (hermetic) and the live dashboard-provisioning tests pass.

## Problem Statement

`centralized_dns` already stands up three exporters (`adguard-exporter` `:9618`,
`unbound_exporter` `:9167`, `node_exporter` `:9100`) and `just up-connected` already
hot-pushes them into the monitoring cluster's Prometheus as jobs `centralized-dns-adguard`,
`centralized-dns-unbound`, `centralized-dns-server` (root `Justfile` ~line 173-177). Those
series are also `remote_write`n into OpenObserve's `metrics` stream. **But there is no
dashboard for any of it** — the DNS metrics are collected and immediately invisible. Every
other exporter in the fleet has a board (`specs/dashboards.md` inventory); DNS is the gap.

The two dashboard surfaces are complementary and both are wanted:
- **Grafana** is the richer visual surface (already the home for node/cadvisor/k8s boards).
- **OpenObserve** dashboards keep the DNS metrics queryable *inside* OpenObserve alongside
  the log streams, for cross-signal work — consistent with the `Infrastructure/*` PromQL
  boards `specs/openobserve-dashboards.md` already ships.

## Solution Approach

Reuse the **drop-a-file** provisioning both surfaces already have — no new mechanics:

1. **Grafana** — drop `adguard-home.json` + `unbound.json` into
   `clusters/centralized_monitoring/cloud-init/grafana/dashboards/DNS/`. `main.tf`'s
   `fileset(local.grafana_dashboard_dir, "**/*.json")` sweep (main.tf:167) picks them up
   automatically; `foldersFromFilesStructure: true` turns `DNS/` into a Grafana folder.
   Every panel/target/template references `{"type":"prometheus","uid":"prometheus"}`
   (the single most common empty-panel cause — `specs/dashboards.md` §3).

2. **OpenObserve** — drop `adguard-home.json` + `unbound.json` into
   `clusters/centralized_monitoring/openobserve/dashboards/DNS/`. `main.tf`'s
   `fileset(local.openobserve_dashboard_dir, "**/*.json")` sweep (main.tf:180), filtered by
   `try(jsondecode(...).title, null) != null`, picks them up; `openobserve-provision.sh`
   POSTs them at boot (and `just openobserve-dashboards` re-imports on demand). Panels are
   `queryType: "promql"` over `stream_type: metrics`, exactly like
   `openobserve/dashboards/Infrastructure/prometheus-health.json`.

3. **Query against confirmed metric names + job labels.** AdGuard series are `adguard_*`
   (from `henrywhitaker3/adguard-exporter`, job `centralized-dns-adguard`), Unbound series
   are `unbound_*` (from `letsencrypt/unbound_exporter`, job `centralized-dns-unbound`). The
   metric names below are drawn from the exporter READMEs and this repo's own
   `clusters/centralized_dns/scripts/unbound_cli.py` (which already asserts `unbound_up`,
   `unbound_queries_total`, `unbound_cache_hits_total`, `unbound_cache_misses_total`,
   `unbound_answers_secure_total`, `unbound_memory_caches_bytes`). **Task 0 confirms the
   full set live** before finalizing (same "confirm field/metric names live" gate the
   OpenObserve dashboards spec uses).

### Where the data comes from (and when panels are empty)

The DNS exporters live on the `centralized-dns-server` VM; they are scraped by the
**monitoring** cluster's Prometheus **only after `just up-connected`** hot-pushes them as
`extra_scrape_targets`. A standalone `just up centralized_monitoring` does **not** scrape
DNS, so these boards render empty until the fleet is brought up connected. This is the same
"populates only when connected" behavior as any cross-cluster board and must be documented
on each dashboard (a text panel header) and in the monitoring cluster README. No attempt is
made to add DNS scraping to the logging cluster's self-contained Prometheus (it only scrapes
`logging-*` jobs — `specs/dashboards.md` §Per-cluster coverage).

### Confirmed metric inventory (basis for panels)

**AdGuard (`adguard-exporter`, job `centralized-dns-adguard`, label `server` = upstream URL):**
`adguard_running`, `adguard_protection_enabled`, `adguard_queries`, `adguard_query_types{type}`,
`adguard_blocked_filtered`, `adguard_blocked_safesearch`, `adguard_blocked_safebrowsing`,
`adguard_avg_processing_time_seconds`, `adguard_avg_processing_time_milliseconds_bucket{le}`,
`adguard_top_queried_domains{domain}`, `adguard_top_blocked_domains{domain}`,
`adguard_top_clients{client}`, `adguard_top_upstreams{upstream}`,
`adguard_top_upstreams_avg_response_time_seconds{upstream}`, `adguard_dhcp_enabled`,
`adguard_dhcp_leases`, `adguard_queries_details`, `adguard_scrape_errors_total`.

> AdGuard `_queries`/`_blocked_*`/`top_*` are **24h-window gauges** (AdGuard's own stats
> window), not counters — chart them directly / with `topk()`, **not** `rate()`. Block % is
> `(adguard_blocked_filtered + adguard_blocked_safesearch + adguard_blocked_safebrowsing) /
> adguard_queries * 100`.

**Unbound (`unbound_exporter`, job `centralized-dns-unbound`, label `thread` on per-thread series):**
`unbound_up`, `unbound_time_up_seconds_total`, `unbound_queries_total{thread}`,
`unbound_cache_hits_total{thread}`, `unbound_cache_misses_total{thread}`,
`unbound_answer_rcodes_total{rcode}`, `unbound_answers_secure_total`, `unbound_answers_bogus_total`,
`unbound_query_types_total{type}`, `unbound_query_classes_total{class}`,
`unbound_query_opcodes_total{opcode}`, `unbound_query_flags_total{flag}`,
`unbound_recursion_time_seconds_avg`, `unbound_recursion_time_seconds_median`,
`unbound_request_list_current_all`, `unbound_request_list_current_user`,
`unbound_request_list_exceeded_total`, `unbound_request_list_overwritten_total`,
`unbound_request_list_max`, `unbound_memory_caches_bytes{cache}`,
`unbound_memory_modules_bytes{module}`, `unbound_rrset_cache_count`, `unbound_msg_cache_count`,
`unbound_unwanted_queries_total`, `unbound_unwanted_replies_total`.

> Unbound `*_total` are **counters** — chart with `rate(...[5m])`. Cache hit ratio:
> `sum(rate(unbound_cache_hits_total[5m])) / (sum(rate(unbound_cache_hits_total[5m])) +
> sum(rate(unbound_cache_misses_total[5m])))`.

## Relevant Files

Use these files to complete the task:

- `clusters/centralized_monitoring/main.tf` (locals ~159-213) — the two dashboard sweeps.
  **Read only; no edit needed** (drop-a-file). Confirms `**/*.json` globbing and the OO
  `title` filter.
- `clusters/centralized_monitoring/cloud-init/grafana/dashboards/Instances/instance-overview.json`
  — the canonical **custom** Grafana board (schemaVersion 39, `uid`, `templating` with an
  `$instance` query var bound to `uid: prometheus`, `stat`/`timeseries` panels). Copy its
  shape for the AdGuard/Unbound boards.
- `clusters/centralized_monitoring/cloud-init/grafana/dashboards/Instances/processes-systemd.json`
  and `Platform/prometheus.json` — more panel-type references (tables, `topk`, bar gauge).
- `clusters/centralized_monitoring/openobserve/dashboards/Infrastructure/prometheus-health.json`
  — the canonical **OpenObserve** PromQL board (v5 schema: `tabs[].panels[]`, `queryType:
  "promql"`, `fields.stream`/`stream_type: metrics`, `config.promql_legend`, `layout`).
  Copy its shape for the OO DNS boards.
- `clusters/centralized_monitoring/cloud-init/grafana/provisioning/dashboards/dashboards.yaml`
  — confirms `foldersFromFilesStructure: true` (DNS/ → folder). Read only.
- `clusters/centralized_monitoring/scripts/openobserve_cli.py` +
  `cloud-init/openobserve/provision.sh` — how OO dashboards are imported (upsert by title).
  Read only; the new JSONs must carry a stable unique `title` + `dashboardId`.
- `clusters/centralized_dns/scripts/unbound_cli.py`, `tests/testinfra/test_metrics.py` —
  ground truth for the `unbound_*` / `adguard_*` metric-name prefixes we actually emit.
- Root `Justfile` (~line 173-177) — the DNS job names (`centralized-dns-adguard`,
  `centralized-dns-unbound`, `centralized-dns-server`) used as the `job=` label in queries.
- `clusters/centralized_monitoring/tests/tofu/sizing_and_render.tftest.hcl` — extend to
  assert the DNS boards splice into cloud-init.
- `clusters/centralized_monitoring/tests/testinfra/test_openobserve_dashboards.py`,
  `test_e2e_scrape.py` (`test_grafana_dashboards_provisioned`) — extend the expected-title lists.

### New Files

Grafana (swept by `main.tf`, written to the VM at boot — needs `just recreate` to reach a
running VM per `CLAUDE.md`):
- `clusters/centralized_monitoring/cloud-init/grafana/dashboards/DNS/adguard-home.json`
- `clusters/centralized_monitoring/cloud-init/grafana/dashboards/DNS/unbound.json`

OpenObserve (swept by `main.tf`, POSTed post-boot by `openobserve-provision.sh` / `just
openobserve-dashboards`):
- `clusters/centralized_monitoring/openobserve/dashboards/DNS/adguard-home.json`
- `clusters/centralized_monitoring/openobserve/dashboards/DNS/unbound.json`

Docs:
- `specs/dashboards.md` — add the two Grafana boards + a `DNS` folder row.
- `specs/openobserve-dashboards.md` — add the two OO boards + a `DNS` folder row.

## Implementation Phases

### Phase 1: Foundation
Confirm the live metric inventory (Task 0) and pick the exact panel set + PromQL for each
board from the community-dashboard inspiration, reconciled to our real metric names.

### Phase 2: Core Implementation
Author the four JSON dashboards (2 Grafana, 2 OpenObserve) to the two established schemas,
bound to `uid: prometheus` / `stream_type: metrics` and the `centralized-dns-*` jobs.

### Phase 3: Integration & Polish
Extend the hermetic render test + live provisioning tests + `check --require-dashboards`
title lists; validate hermetically and live; update the two dashboard specs.

## Step by Step Tasks

IMPORTANT: Execute every step in order, top to bottom.

### 1. Task 0 — confirm the live metric inventory
- Bring the fleet up connected (`just up-connected`) so DNS exporters are scraped.
- Dump the real series to reconcile against the inventory above:
  - `curl -s http://<dns_ip>:9618/metrics | grep '^adguard_' | sort -u`
  - `curl -s http://<dns_ip>:9167/metrics | grep '^unbound_' | sort -u`
  - `just prometheus-query centralized_monitoring 'group by (__name__)({job=~"centralized-dns.*"})'`
- Note the actual label names (e.g. AdGuard's `server`, Unbound's `thread`) and whether
  `unbound_rrset_cache_count` / `unbound_msg_cache_count` are present on the installed build.
  Adjust the panel queries in later steps to match. Record any deviation from the inventory
  in the two dashboard specs.

### 2. Author `Grafana DNS/adguard-home.json`
- Copy the skeleton of `Instances/instance-overview.json`: `schemaVersion: 39`,
  `refresh: "30s"`, `time: {from: "now-6h"}`, stable top-level `"uid": "adguard-home"`,
  `"title": "AdGuard Home"`, `tags: ["dns","adguard"]`. **Every** `datasource` is
  `{"type":"prometheus","uid":"prometheus"}`.
- Optional templating var `$instance` = `label_values(adguard_running, instance)`
  (single DNS VM today; keeps the board multi-instance-ready like grafana.com 24520).
- Panels (id/gridPos laid out top-to-bottom):
  - **Stat row**: `adguard_running` (UP/DOWN mapping), `adguard_protection_enabled`
    (ON/OFF), `adguard_queries` (24h total), blocked total
    `adguard_blocked_filtered + adguard_blocked_safesearch + adguard_blocked_safebrowsing`,
    **Block %** `(sum(adguard_blocked_filtered)+sum(adguard_blocked_safesearch)+sum(adguard_blocked_safebrowsing))/sum(adguard_queries)*100` (unit `percent`),
    avg processing time `adguard_avg_processing_time_seconds` (unit `s`).
  - **Timeseries — Queries vs Blocked**: `adguard_queries` and the blocked sum over time
    (these are 24h-window gauges; plot directly, no `rate()`).
  - **Piechart/bar — Query types**: `adguard_query_types` legend `{{type}}`.
  - **Bar gauge — Top queried domains**: `topk(10, adguard_top_queried_domains)` legend `{{domain}}`.
  - **Bar gauge — Top blocked domains**: `topk(10, adguard_top_blocked_domains)` legend `{{domain}}`.
  - **Table — Top clients**: `topk(10, adguard_top_clients)` legend `{{client}}`.
  - **Table — Top upstreams + avg response**: `adguard_top_upstreams` and
    `adguard_top_upstreams_avg_response_time_seconds` (unit `s`) legend `{{upstream}}`.
  - **Heatmap — Processing-time distribution**: `adguard_avg_processing_time_milliseconds_bucket`
    (format `heatmap`), `le` buckets.
  - **Stat (optional)**: `adguard_dhcp_leases` gated visually (DHCP is off in this lab —
    include but expect 0; note in a text panel).
  - **Text panel (top)**: "Populates only after `just up-connected` scrapes
    `centralized-dns-adguard`."
- `jq empty` must pass.

### 3. Author `Grafana DNS/unbound.json`
- Same skeleton; `"uid": "unbound"`, `"title": "Unbound Resolver"`, `tags: ["dns","unbound"]`,
  all datasources `uid: prometheus`. Optional `$instance` =
  `label_values(unbound_up, instance)`.
- Panels:
  - **Stat row**: `unbound_up` (UP/DOWN), uptime `unbound_time_up_seconds_total` (unit `s`),
    total queries `sum(unbound_queries_total)`, **Cache hit ratio**
    `sum(rate(unbound_cache_hits_total[5m]))/(sum(rate(unbound_cache_hits_total[5m]))+sum(rate(unbound_cache_misses_total[5m])))`
    (unit `percentunit`), avg recursion time `unbound_recursion_time_seconds_avg` (unit `s`).
  - **Timeseries — Query rate**: `sum(rate(unbound_queries_total[5m]))`.
  - **Timeseries — Cache hits vs misses**: `sum(rate(unbound_cache_hits_total[5m]))`,
    `sum(rate(unbound_cache_misses_total[5m]))`.
  - **Timeseries — Cache hit ratio %** (same formula as the stat, over time).
  - **Timeseries/stacked — Answer RCODEs**: `sum by (rcode)(rate(unbound_answer_rcodes_total[5m]))`
    legend `{{rcode}}`.
  - **Timeseries — DNSSEC**: `rate(unbound_answers_secure_total[5m])` and
    `rate(unbound_answers_bogus_total[5m])`.
  - **Bar/pie — Query types**: `sum by (type)(rate(unbound_query_types_total[5m]))` legend `{{type}}`.
  - **Timeseries — Recursion time**: `unbound_recursion_time_seconds_avg`,
    `unbound_recursion_time_seconds_median`.
  - **Timeseries — Request list**: `unbound_request_list_current_all`,
    `unbound_request_list_current_user`, `unbound_request_list_max`, plus
    `rate(unbound_request_list_exceeded_total[5m])`.
  - **Bar gauge — Cache memory**: `unbound_memory_caches_bytes` legend `{{cache}}` (unit `bytes`),
    and `unbound_memory_modules_bytes` legend `{{module}}`.
  - **Timeseries — Unwanted**: `rate(unbound_unwanted_queries_total[5m])`,
    `rate(unbound_unwanted_replies_total[5m])`.
  - **Text panel (top)**: same "populates after `just up-connected`" note.
- `jq empty` must pass.

### 4. Author `OpenObserve DNS/adguard-home.json`
- Copy `openobserve/dashboards/Infrastructure/prometheus-health.json`: top-level `version: 5`,
  `dashboardId: "dns-adguard-home"`, `title: "AdGuard Home"`, `description`, `owner`, `role`,
  `variables: {list: [], showDynamicFilters: false}`, one `tabs[0]` (`tabId: "default"`).
- For each Grafana panel above, add an OO panel object: `type` (`stat`/`line`/`bar`/`table`),
  `queryType: "promql"`, `queries[0].query` = the PromQL, `queries[0].customQuery: true`,
  `queries[0].fields.stream` = a representative metric name (e.g. `adguard_queries`),
  `fields.stream_type: "metrics"`, `config.promql_legend` = the legend template
  (`{{type}}`/`{{domain}}`/…), and a `layout {x,y,w,h,i}` on the 24-col grid (mirror the
  reference's `w:24`/`w:12` tiling and increment `i`). Keep `rate()`/`topk()` identical.
- Give panels unique `id`s (`panel_adguard_queries`, `panel_adguard_block_pct`, …).
- Validate: `jq -e '.title and .tabs[0].panels' DNS/adguard-home.json`.

### 5. Author `OpenObserve DNS/unbound.json`
- Same as step 4 for the Unbound panel set; `dashboardId: "dns-unbound"`,
  `title: "Unbound Resolver"`. Representative `fields.stream` e.g. `unbound_queries_total`.
- Validate with `jq -e '.title and .tabs[0].panels'`.

### 6. Extend the hermetic render test
- In `clusters/centralized_monitoring/tests/tofu/sizing_and_render.tftest.hcl`, add
  assertions that `local_file`/rendered server cloud-init contains the Grafana DNS board
  paths (e.g. `DNS/adguard-home.json`) — mirroring the existing "splices a dashboard file"
  assertion in `specs/dashboards.md` §Testing. The gz+b64 loop stays valid YAML
  (`can(yamldecode(...))`).

### 7. Extend the live provisioning tests + `check`
- `tests/testinfra/test_e2e_scrape.py::test_grafana_dashboards_provisioned` — add
  `AdGuard Home` / `Unbound Resolver` (uids `adguard-home`, `unbound`) to the expected set;
  a `GET /api/dashboards/uid/adguard-home` returns 200.
- `tests/testinfra/test_openobserve_dashboards.py` — add the two OO titles to the expected
  list (flag-gated on `enable_openobserve`).
- `openobserve_cli.py check --require-dashboards` expected-title list — add both OO titles
  (per `specs/openobserve-dashboards.md` §`check` semantics).

### 8. Update the specs
- `specs/dashboards.md` — add a `DNS` folder row to the taxonomy + the two Grafana boards
  to the custom-authored inventory (note: cross-cluster, populates after `up-connected`).
- `specs/openobserve-dashboards.md` — add a `DNS` folder row + the two OO boards; note the
  metric-name basis (henrywhitaker3 / letsencrypt exporters) and job labels.

### 9. Validate
- Hermetic: `just check centralized_monitoring`; `jq empty` on all four new JSONs;
  `jq -e '.title and .tabs[0].panels'` on the two OO JSONs.
- `tofu -chdir=clusters/centralized_monitoring fmt -check -recursive`.
- Live: `just up-connected` (so DNS is scraped) → `just recreate centralized_monitoring`
  (Grafana boards ship via cloud-init) → `just openobserve-dashboards centralized_monitoring`
  (import OO boards) → `just verify centralized_monitoring` → `just verify-api centralized_monitoring`.
- Visual: `just open centralized_monitoring` (Grafana DNS folder) + the OpenObserve UI DNS folder.

## Testing Strategy

Two-layer split, mirroring `specs/dashboards.md` / `specs/openobserve-dashboards.md`:

- **Hermetic** (`just check centralized_monitoring`, no VMs): the render test asserts the
  DNS Grafana JSONs are spliced into cloud-init and the datasource render declares
  `uid: prometheus`; a JSON-validity test (`jq empty` / OO `.title`+`.panels`) covers all
  four files. This closes the gap where a malformed board or wrong datasource uid ships
  silently and renders empty.
- **Live** (`just verify` / `just verify-api`): Grafana `GET /api/search?type=dash-db`
  contains `AdGuard Home` + `Unbound Resolver`; OO `GET /api/default/dashboards` contains
  both titles; `check --require-dashboards` exits 0. **Panel-level data assertions are out
  of scope** (flaky, and the DNS series only exist post-`up-connected`) — `just open` +
  the OpenObserve UI cover visual confirmation, exactly as the other dashboard specs decree.

Edge cases: (a) board renders empty on a standalone (non-connected) monitoring stack —
expected, documented via a text panel + README note; (b) AdGuard 24h-window gauges must
**not** be wrapped in `rate()` while Unbound `*_total` counters **must** be — enforced by
Task 0's live reconcile; (c) a metric absent on the installed exporter build (e.g.
`unbound_msg_cache_count`) — Task 0 catches it, drop or swap that panel rather than shipping
a permanently-empty one (`specs/dashboards.md` §"No dead panels").

## Acceptance Criteria

- Four dashboards exist: Grafana `DNS/{adguard-home,unbound}.json` (datasource
  `uid: prometheus`, folder `DNS`) and OpenObserve `DNS/{adguard-home,unbound}.json`
  (`queryType: promql`, `stream_type: metrics`).
- All four are picked up **with zero `main.tf` edits** by the existing `**/*.json` sweeps;
  `DNS/` shows as a folder in both Grafana and OpenObserve.
- Every panel query uses a confirmed `adguard_*` / `unbound_*` metric name and the
  `centralized-dns-adguard` / `centralized-dns-unbound` (/`-server`) job labels; AdGuard
  window-gauges are plotted raw, Unbound counters via `rate()`.
- After `just up-connected` + `just recreate centralized_monitoring` +
  `just openobserve-dashboards centralized_monitoring`, both surfaces show DNS boards that
  populate with live data (query volume, block %, cache hit ratio, DNSSEC, top domains/clients).
- `just check centralized_monitoring` passes; the render test asserts the DNS boards splice
  in; the live provisioning tests + `check --require-dashboards` list both new titles.
- `jq empty` passes on all four files; `tofu fmt -check` is clean.

## Validation Commands

Execute these commands to validate the task is complete:

- `jq empty clusters/centralized_monitoring/cloud-init/grafana/dashboards/DNS/adguard-home.json clusters/centralized_monitoring/cloud-init/grafana/dashboards/DNS/unbound.json` — Grafana JSON validity.
- `jq -e '.title and .tabs[0].panels' clusters/centralized_monitoring/openobserve/dashboards/DNS/adguard-home.json clusters/centralized_monitoring/openobserve/dashboards/DNS/unbound.json` — OO schema keys present.
- `just check centralized_monitoring` — hermetic fmt + validate + tofu test (render test now covers the DNS boards).
- `tofu -chdir=clusters/centralized_monitoring fmt -check -recursive` — formatting gate.
- `cd clusters/centralized_monitoring/tests/openobserve && uv run pytest -v` — CLI/dashboard hermetic suite (updated title lists).
- Live (fleet up): `just up-connected && just recreate centralized_monitoring && just openobserve-dashboards centralized_monitoring && just verify centralized_monitoring && just verify-api centralized_monitoring`.
- Visual: `just open centralized_monitoring` (Grafana `DNS` folder) + OpenObserve UI on `:5080` (`DNS` folder).

## Notes

- **No new libraries.** Dashboards are pure JSON consumed by existing provisioning; the OO
  importer/CLI already exist (`openobserve_cli.py dashboards import`).
- **`just up` vs `just recreate`.** Grafana boards ship via cloud-init `write_files`, so a
  running monitoring VM needs `just recreate centralized_monitoring` (a plain `just up`
  silently reuses stale cloud-init — `CLAUDE.md`, `specs/ntp.md`). During iteration, `scp`
  the JSON onto `/opt/stack/grafana/dashboards/DNS/` and let Grafana's file provider reload
  (it re-reads on an interval) — far faster than a recreate — then fold back into the repo.
  OpenObserve boards need no recreate at all: re-run `just openobserve-dashboards` (idempotent
  upsert by title) against the running VM.
- **Datasource uid is load-bearing.** Any Grafana panel/target/template left on a `${DS_*}`
  or name-based datasource renders empty — rewrite **all** of them to
  `{"type":"prometheus","uid":"prometheus"}` (`specs/dashboards.md` §3). For OpenObserve the
  equivalent is `fields.stream_type: "metrics"` + `queryType: "promql"`.
- **Metric-name drift.** The exporter versions are pinned in `centralized_dns` but the
  `henrywhitaker3` / `letsencrypt` metric names can shift across releases; Task 0's live
  reconcile is the guard, and any deviation is recorded in the two dashboard specs.
- **`pre_tool_use` hook** matches substrings — when reconciling metrics live, avoid `grep`ing
  with a bare `rm `/`.env` token in the command (per `CLAUDE.md` "Working fast" notes).
- **Optional follow-up:** a combined `DNS/dns-overview.json` (AdGuard block-rate + Unbound
  cache-ratio + `up{job=~"centralized-dns.*"}` on one pane) for an at-a-glance fleet-DNS
  health tile — left out of scope unless requested.
```