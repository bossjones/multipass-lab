# Plan: Wire OpenObserve ingestion (metrics + host/container logs) — TDD

## Task Description

`clusters/centralized_monitoring/` deploys OpenObserve (`:5080`, `enable_openobserve=true`, root
creds `admin@example.com` / `Complexpass#123`) but **nothing is ever ingested**. This plan connects
metrics **and** logs — host-level logs and container logs, from both cluster VMs — into OpenObserve,
built test-first per the repo's two-layer split (hermetic tofu + live testinfra) and its uv CLI
convention.

Investigation found four independent breaks:

1. **No producer.** The OTel Collector (`cloud-init/otel/collector-config.yaml`) is a passive OTLP
   gateway — nothing pushes to `:4317/:4318`. All real telemetry is Prometheus **pull**
   (node_exporter, cadvisor, netdata, kube-state-metrics, …) and lands only in Prometheus's TSDB.
2. **Wrong auth.** The exporter header `Basic cm9vdEBleGFtcGxlLmNvbTphZG1pbg==` decodes to
   `root@example.com:admin` — wrong user *and* password → every export would `401`
   (`collector-config.yaml:25`).
3. **Metrics never routed to OpenObserve.** The OTel `metrics` pipeline exports to the internal
   `prometheus` exporter on `:8889` (which isn't even scraped), not to OpenObserve
   (`collector-config.yaml:43-46`).
4. **No Prometheus `remote_write`.** `prometheus.yml.tftpl` has only `scrape_configs` + Alertmanager.

**Structural constraint:** the k0s client VM is created **before** the server (`main.tf:57-71` then
`138-145`) so Prometheus can render the client's DHCP IP. Therefore k0s cloud-init **cannot** know
the server IP at render time — pushing k0s logs to OpenObserve needs a post-apply IP-injection step.

## Objective

After `just recreate centralized_monitoring`, OpenObserve stores real data:

- **Metrics** — Prometheus `remote_write` → `http://openobserve:5080/api/default/prometheus/api/v1/write`
  (basic auth). One block ships *all* scraped series (server + k0s) into OpenObserve.
- **Server logs** — extend the existing OTel Collector with `filelog` receivers for Docker
  container logs (`/var/lib/docker/containers/*/*.log`) and host logs (`/var/log/syslog`), fix the
  auth, template the password → `container_logs` / `host_logs` streams.
- **k0s logs** — an `otelcol-contrib` systemd agent on the k0s VM ships host logs
  (`/var/log/syslog`) + Kubernetes pod logs (`/var/log/pods/*/*/*.log`) to the server's
  OpenObserve; its endpoint is injected post-apply via `terraform_data` + `multipass exec`.

Everything feature-flagged, rendered from templates, and covered by the repo's two-layer tests.

## Problem Statement

OpenObserve is deployed and healthy but empty, so the Grafana OpenObserve datasource returns no
series and the tool provides zero value. The design decision (chosen with the user): **reuse the
already-deployed OTel Collector** for logs (rather than adding Vector/Fluent Bit), take the standard
**Prometheus `remote_write`** path for metrics, and give **full coverage** — server logs + all
metrics immediately, k0s logs via a post-apply step forced by the reverse create-ordering.

## Solution Approach

Reuse what's deployed. OTel Collector already runs on the server and already has a (broken)
OpenObserve exporter — fix + expand it. Metrics take `remote_write` (Prometheus already scrapes
everything, incl. k0s). k0s is the only piece needing new machinery, and the reverse create-ordering
forces a post-apply push.

### Target architecture

```
  ┌── k0s VM (created 1st) ─────────────┐        ┌── server VM (created 2nd) ─────────────────┐
  │ exporters (:9100/:8089/…) ◄── pull ─┼────────┼─ Prometheus ──remote_write──► OpenObserve   │
  │ otelcol-contrib (systemd)           │  push  │                                   ▲  :5080  │
  │  filelog: /var/log/syslog           ├────────┼───────────────────────────────────┘         │
  │  filelog: /var/log/pods/*           │  OTLP  │  OTel Collector (container)                   │
  │  endpoint injected POST-APPLY ──────┘        │   filelog /var/lib/docker/containers ─► OO    │
  │                                              │   filelog /var/log/syslog ───────────► OO    │
  └──────────────────────────────────────────────┘   otlp (:4317/:4318) ────────────► OO       │
                                                   └───────────────────────────────────────────┘
  OpenObserve streams: metrics (remote_write) | container_logs | host_logs | k0s_host | k0s_pods
```

## Relevant Files

Modify:
- `clusters/centralized_monitoring/cloud-init/otel/collector-config.yaml` → **rename to
  `collector-config.yaml.tftpl`**; fix auth, add `filelog` receivers + log pipelines, template
  `${openobserve_password}` / `${openobserve_org}`.
- `clusters/centralized_monitoring/cloud-init/docker/compose.yaml.tftpl:78-91` — mount
  `/var/lib/docker/containers:ro` and `/var/log:ro` into `otel-collector` (+ optional
  `file_storage` checkpoint volume).
- `clusters/centralized_monitoring/cloud-init/prometheus/prometheus.yml.tftpl` — add
  `%{ if enable_openobserve ~} remote_write: … %{ endif ~}`.
- `clusters/centralized_monitoring/cloud-init/k0s-client.yaml.tftpl` — install `otelcol-contrib`
  binary, systemd unit, placeholder config; ensure `/var/log/pods` readable.
- `clusters/centralized_monitoring/main.tf` — `otel_config` `file()`→`templatefile()`; thread
  `openobserve_password`+`openobserve_org` into `prometheus_yml`; add `local.openobserve_org`;
  add `local_file.k0s_otel_config` (rendered from `multipass_instance.server.ipv4`) +
  `terraform_data.k0s_log_shipper` (local-exec `multipass transfer`/`exec`).
- `clusters/centralized_monitoring/variables.tf` — add `enable_k0s_log_shipping` (default `true`).
- `clusters/centralized_monitoring/scripts/openobserve_cli.py:254-316` — extend `check` with
  `--require-metrics` (PromQL `up`) and `--require-logs` (a log stream has rows).
- Tests: `clusters/centralized_monitoring/tests/tofu/sizing_and_render.tftest.hcl`,
  `clusters/centralized_monitoring/tests/openobserve/test_openobserve_cli.py`.
- Docs: `specs/centralized_monitoring.md` (OpenObserve section + flags table), `docs/feature-flags.md`.

### New Files
- `clusters/centralized_monitoring/cloud-init/otel/k0s-collector-config.yaml.tftpl` — k0s agent
  config, rendered from the server IP (endpoint + auth) after the server exists.
- `clusters/centralized_monitoring/tests/testinfra/test_openobserve_ingest.py` — live ingestion
  round-trip tests.

## Implementation Phases

### Phase 1 — Metrics (fastest win, no ordering issues)
Prometheus `remote_write` → OpenObserve. Get *something* visibly ingested end-to-end first.

### Phase 2 — Server logs
Fix + template the OTel collector, add filelog receivers + mounts, split into `container_logs` /
`host_logs` streams.

### Phase 3 — k0s logs (post-apply)
otelcol-contrib systemd agent on k0s + `terraform_data` IP injection.

### Phase 4 — CLI check + docs
Make `just verify-api` actually assert ingestion; update specs/docs.

## Step by Step Tasks
IMPORTANT: Execute every step in order. Each behavior gets its hermetic test written **first**
(red), then the config change (green) — per `superpowers:test-driven-development` and the repo's
two-layer split.

### 1. Constants & flag scaffolding
- In `main.tf` add `local.openobserve_org = "default"` next to `local.openobserve_password`.
- In `variables.tf` add `enable_k0s_log_shipping` (bool, default `true`) with a doc comment; add it
  to `local.flags` in `main.tf` so it renders + appears in `enabled_exporters`.

### 2. Metrics — write hermetic test (red)
- In `tests/tofu/sizing_and_render.tftest.hcl` add assertions to the default run against
  `local_file.server_ci.content` (prometheus.yml is spliced in): contains `remote_write`, the
  OpenObserve write URL `.../api/default/prometheus/api/v1/write`, `username: admin@example.com`,
  and the password.
- Add a toggle run `openobserve_off_omits_remote_write` (`enable_openobserve = false`) asserting
  `!strcontains(..., "remote_write")`.
- Run `just check centralized_monitoring` → expect FAIL.

### 3. Metrics — implement (green)
- `prometheus.yml.tftpl`: append after `scrape_configs`:
  ```yaml
  %{ if enable_openobserve ~}
  remote_write:
    - url: http://openobserve:5080/api/${openobserve_org}/prometheus/api/v1/write
      basic_auth:
        username: admin@example.com
        password: ${openobserve_password}
  %{ endif ~}
  ```
- `main.tf`: extend the `prometheus_yml` templatefile map with
  `openobserve_password = local.openobserve_password` and `openobserve_org = local.openobserve_org`.
- `just check centralized_monitoring` → expect PASS.

### 4. Server logs — write hermetic test (red)
- Assert `local_file.server_ci.content`:
  - collector config auth = `Basic ` + base64(`admin@example.com:Complexpass#123`)
    (compute the literal and `strcontains`).
  - contains filelog includes `/var/lib/docker/containers/*/*.log` and `/var/log/syslog`.
  - contains `logs/container` and `logs/host` pipelines (or the stream names `container_logs`,
    `host_logs`).
  - compose renders otel-collector volumes `/var/lib/docker/containers:/var/lib/docker/containers:ro`
    and `/var/log:/var/log:ro`.
  - `can(yamldecode(local_file.server_ci.content))` still true.
- Run `just check` → FAIL.

### 5. Server logs — implement (green)
- Rename `collector-config.yaml` → `collector-config.yaml.tftpl`. New content:
  - `receivers.otlp` (unchanged) + `filelog/container` (docker json: `json_parser` on the `log`
    field, move to `body`, parse `time`) + `filelog/host` (plain lines from `/var/log/syslog`).
  - `processors`: `batch`, `resource/container` (`service.name=container_logs`),
    `resource/host` (`service.name=host_logs`).
  - `exporters.otlphttp/openobserve`: `endpoint: http://openobserve:5080/api/${openobserve_org}`,
    `headers.Authorization: "Basic ${base64encode("admin@example.com:${openobserve_password}")}"`
    (rendered by templatefile).
  - `pipelines`: `logs/otlp`, `logs/container`, `logs/host` all → `[otlphttp/openobserve]`;
    keep `traces` → OpenObserve; leave `metrics` → prometheus exporter (metrics reach OO via
    remote_write). *Verify OpenObserve stream naming during Step 9; adjust `resource`/`stream-name`
    header if streams collapse to `default`.*
- `main.tf`: change `otel_config = file(...)` →
  `templatefile(".../collector-config.yaml.tftpl", merge(local.flags, { openobserve_password = local.openobserve_password, openobserve_org = local.openobserve_org }))`.
- `compose.yaml.tftpl` otel-collector `volumes`: add the two read-only host mounts (and optional
  `otel_storage:/var/lib/otelcol` + a `file_storage` extension so filelog checkpoints survive
  restarts; declare the volume under `volumes:` gated on `enable_otel`).
- `just check` → PASS.

### 6. k0s logs — write hermetic test (red)
- Assert `local_file.k0s_ci.content` (when `enable_k0s_log_shipping`): installs `otelcol-contrib`,
  writes a systemd unit (`otelcol`), references `/var/log/pods` and `/var/log/syslog`.
- Assert the k0s config `local_file.k0s_otel_config.content` renders the server IP
  (`10.99.99.99:5080` from the mock) and the auth header.
- Toggle run `k0s_log_shipping_off_omits_agent` → `!strcontains(k0s_ci, "otelcol")`.
- Run `just check` → FAIL.

### 7. k0s logs — implement (green)
- `k0s-client.yaml.tftpl` (gated `%{ if enable_k0s_log_shipping ~}`): `runcmd` downloads the
  `otelcol-contrib` release tarball, installs the binary to `/usr/local/bin`, writes a systemd
  unit pointing at `/etc/otelcol/collector-config.yaml`, and writes a **placeholder** config
  (endpoint blank/localhost) so the unit exists but is inert until injected. Ensure the ubuntu
  user / collector can read `/var/log/pods` and `/var/log/syslog`.
- New `cloud-init/otel/k0s-collector-config.yaml.tftpl`: filelog `/var/log/syslog`
  (`service.name=k0s_host`) + `/var/log/pods/*/*/*.log` (`service.name=k0s_pods`, k8s log
  operators) → otlphttp `http://${server_ip}:5080/api/${openobserve_org}` with the auth header.
- `main.tf`:
  - `local_file.k0s_otel_config` = `templatefile(k0s-collector-config.yaml.tftpl, { server_ip =
    multipass_instance.server.ipv4, openobserve_password, openobserve_org })` →
    `${render_dir}/k0s-collector-config.yaml`.
  - `terraform_data.k0s_log_shipper` (`count = var.enable_openobserve && var.enable_k0s_log_shipping ? 1 : 0`),
    `triggers_replace = [multipass_instance.server.ipv4, local.openobserve_password, local_file.k0s_otel_config.content]`,
    `provisioner "local-exec"`:
    `multipass transfer ${local_file.k0s_otel_config.filename} ${local.k0s_name}:/tmp/otel.yaml`
    then `multipass exec ${local.k0s_name} -- sudo cp /tmp/otel.yaml /etc/otelcol/collector-config.yaml`
    then `... sudo systemctl restart otelcol`.
  - Depends implicitly on both instances via the referenced attributes. `command = plan` +
    `mock_provider` never runs local-exec, so hermetic tests stay VM-free.
- `just check` → PASS.

### 8. CLI check — hermetic (red→green)
- `tests/openobserve/test_openobserve_cli.py`: add tests (pytest-httpserver + `CliRunner`) for
  `--require-metrics` (PromQL `up` returns a result → pass; empty → exit 2) and `--require-logs`
  (a log stream present with rows → pass; none → exit 2), mirroring the existing 401/require-streams
  cases.
- `openobserve_cli.py` `check`: add `--require-metrics` (GET `/api/{org}/prometheus/api/v1/query?query=up`,
  assert `data.result` non-empty) and `--require-logs` (reuse `streams` filtered to `logs` +
  `_search` a recent window returns ≥1 row). Use `oc.CheckReport` like the existing checks.
- `uv run --project tests/openobserve pytest` → PASS.

### 9. Live verification (behavioral)
- `just recreate centralized_monitoring` (cloud-init changed → recreate, not up).
- New `tests/testinfra/test_openobserve_ingest.py` using `server` + `enabled_exporters` fixtures and
  the `_curl_json` / `poll` helpers:
  - metrics: poll OpenObserve PromQL `up` on the server VM until a series returns.
  - logs: poll `GET /api/default/streams` until `container_logs` + `host_logs` appear, then
    `_search` each for ≥1 recent row.
  - k0s logs: poll for `k0s_host` / `k0s_pods` streams (skip if `enable_k0s_log_shipping` absent).
  - **This is where OTLP stream naming is confirmed** — if OpenObserve files OTLP logs under
    `default` instead of the intended streams, adjust the `resource` processor / `stream-name`
    header in the collector configs and re-run.
- `just verify centralized_monitoring` and `just verify-api centralized_monitoring` → PASS.

### 10. Docs + final validation
- Update `specs/centralized_monitoring.md` (OpenObserve/OTel section, flags table row for
  `enable_k0s_log_shipping`, "Future work" cleanup) and `docs/feature-flags.md`.
- Run the full validation command block below.

## Testing Strategy

- **Hermetic (tofu, `just check`)** — structural: remote_write block, collector auth/receivers/
  pipelines, compose mounts, k0s agent install + rendered server IP, and negative toggles. No VMs.
- **Hermetic (CLI, pytest-httpserver)** — `check --require-metrics/--require-logs` pass/fail exit
  codes against a fake OpenObserve.
- **Live (testinfra, `just verify`)** — real ingestion round-trip: metrics queryable, log streams
  created + populated (server and k0s). Flag-gated skips via `enabled_exporters`.
- **Live (CLI, `just verify-api`)** — `openobserve_cli.py check` asserts metrics + logs present.
- Edge cases: `enable_openobserve=false` (no remote_write, no otlphttp), `enable_otel=false`
  (no collector), `enable_k0s_log_shipping=false` (no k0s agent), collector restart (filelog
  checkpoint via file_storage), weak-password rejection (already handled by the strong constant).

## Acceptance Criteria
- After `just recreate centralized_monitoring`, OpenObserve `default` org contains: a metrics
  stream with `up`/node/cadvisor series (server **and** k0s), and `container_logs` + `host_logs`
  log streams with recent rows.
- After the post-apply `terraform_data` runs, `k0s_host` + `k0s_pods` streams contain rows.
- The Grafana "OpenObserve" datasource returns non-empty series for `up`.
- `just check centralized_monitoring` passes (all new hermetic assertions + negative toggles).
- `just verify centralized_monitoring` and `just verify-api centralized_monitoring` pass.
- Disabling `enable_openobserve` cleanly removes remote_write + OTLP export; disabling
  `enable_k0s_log_shipping` removes the k0s agent — both proven by hermetic toggle runs.

## Validation Commands
- `just check centralized_monitoring` — hermetic tofu (fmt + validate + test), no VMs.
- `cd clusters/centralized_monitoring && uv run --project tests/openobserve pytest -v` — CLI hermetic.
- `just recreate centralized_monitoring` — redeploy cloud-init (required after `.tftpl` edits).
- `just verify centralized_monitoring` — live testinfra incl. `test_openobserve_ingest.py`.
- `just verify-api centralized_monitoring` — live `openobserve_cli.py check` (metrics + logs).
- `just openobserve-streams centralized_monitoring` — eyeball the created streams.
- `just openobserve-search centralized_monitoring "SELECT * FROM container_logs LIMIT 5"` — spot-check.

## Notes
- Editing `.tftpl` requires `just recreate` (not `just up`) — OpenTofu won't recreate a VM on
  cloud-init content change alone (see CLAUDE.md).
- `terraform_data` is built-in (needs `required_version >= 1.4`; repo pins `>= 1.7`) — no new
  provider. `local-exec` runs only at apply, so hermetic `command = plan` tests never shell out.
- Keep the OpenObserve password as the shared `local.openobserve_password` constant; it must match
  the container env, the Grafana datasource, remote_write, and both collector auth headers.
- OTLP→OpenObserve stream naming is the one empirical unknown; the live tests in Step 9 are the
  gate that forces the config to be correct rather than assumed.
