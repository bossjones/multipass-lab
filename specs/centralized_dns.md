# Plan: `centralized_dns` cluster (AdGuard Home + Unbound, host-level, systemd-managed)

Status: **planned** · Task type: **feature** · Complexity: **complex**
Reference consumer pattern: `centralized_pki` · Hubs it joins: `centralized_logging`, `centralized_monitoring`
Design inspiration: `~/dev/bossjones/adguardhome-unbound-macos-setup` (`install.sh`, `tools/adguardctl`)
HA extension: `specs/ha-dns.md` adds an opt-in `enable_ha` mode (keepalived VRRP VIP +
AdGuardHome-Sync) on top of this single-VM design — read this spec first, then that one.

## Task Description

Add a new vendored cluster `clusters/centralized_dns/` that runs a network-wide DNS
resolver on a single Multipass VM:

- **AdGuard Home** — ad/tracker-blocking DNS front-end, listening on `0.0.0.0:53`, web
  UI + control API on `:3000`.
- **Unbound** — recursive, DNSSEC-validating upstream resolver, listening on
  `127.0.0.1:5335`. AdGuard Home forwards to it; nothing else may query it.
- **Exporters** — `adguard-exporter` (`:9618`), `unbound_exporter` (`:9167`), and the
  shared `node_exporter` (`:9100`) for Prometheus scraping.

Both DNS utilities must be installed **at the host VM level and managed by systemd**
(NOT Docker), mirroring how the macOS reference installs them as LaunchDaemons. The
`tools/adguardctl/docker/*` configs are used only as *config content* references, not as
a deployment method.

This cluster becomes a **new cross-cluster hub**: it must come up **first** so that when
`just up-connected` runs, every other VM in the fleet (both telemetry hubs and every
consumer) is configured at first boot to use AdGuard Home as its DNS resolver. The DNS
VM's own OS + service logs ship to `centralized_monitoring`'s OpenObserve (and the
`centralized_logging` syslog-ng collector), and its exporters are scraped by Prometheus.

Host-side **uv single-file CLIs** (`adguard_cli.py`, `unbound_cli.py`) provide
introspection + a CI-style `check`, drawing design inspiration from `tools/adguardctl`.

## Objective

`just up centralized_dns` stands up a turnkey, isolated AdGuard-Home-over-Unbound
resolver VM with all three exporters live. `just up-connected` brings the whole fleet up
with **centralized_dns first**, wires every other VM's resolver to it, ships the DNS
VM's logs to OpenObserve, and adds its exporters to Prometheus. `just verify centralized_dns`,
`just verify-api centralized_dns`, and `just verify-connected` all pass.

## Problem Statement

Every existing cluster is a self-contained OpenTofu root module wired into two hubs
(`centralized_logging`, `centralized_monitoring`) via opt-in cross-cluster telemetry
(`specs/cross-cluster.md`). There is currently **no DNS hub**: VMs resolve names via the
Multipass-provided resolver, and there is no way to (a) run a lab-wide ad-blocking DNS
service or (b) force every fleet VM to resolve through it.

Adding DNS introduces a **new cross-cluster signal** with a different ordering constraint
than the existing three:

| Signal | Model | Who needs whose IP | Ordering consequence |
|---|---|---|---|
| Logs → syslog-ng | PUSH | consumer needs logging hub IP | logging up early |
| Logs/traces → OpenObserve | PUSH | consumer needs monitoring hub IP | monitoring up early |
| Metrics ← Prometheus | PULL | monitoring hub needs consumer IPs | hot-pushed after |
| **DNS → AdGuard Home** | **PULL-at-resolve / config-PUSH** | **every VM needs the DNS hub IP at first boot** | **DNS up FIRST** |

Because *every* VM (including both telemetry hubs) must know the DNS hub IP at its own
first boot to set its resolver, **centralized_dns must be applied before anything else**.
This is the mirror image of the telemetry hubs (which are pure sinks that come up
early but need nobody's IP). The DNS hub is a pure `:53` sink that needs nobody's IP
either — so it slots in *before* logging.

The one tension: the DNS hub also wants to be a telemetry **consumer** (ship its own logs,
expose its exporters), but the telemetry hubs boot *after* it. This is resolved exactly
like the existing Prometheus scrape-target problem: the DNS hub boots first as a pure
resolver, and its own telemetry wiring is **hot-pushed** after the hubs exist — no VM
recreate, so the DNS IP the whole fleet points at never churns.

## Solution Approach

1. **New cluster `clusters/centralized_dns/`** — a single VM (`role = server`, VM name
   `centralized-dns-server`, matching `centralized_monitoring`'s single-hub shape). Its
   cloud-init installs Unbound (apt), AdGuard Home (official installer → systemd unit),
   `adguard-exporter` + `unbound_exporter` (binaries → systemd units), and the shared
   `node_exporter`. AdGuard Home is **pre-seeded** with a rendered `AdGuardHome.yaml`
   (admin user + `127.0.0.1:5335` upstream + blocklists) so the setup wizard is skipped
   and boot is fully non-interactive.

2. **New standard cross-cluster variable `dns_server`** (string, default `""`), added to
   the shared contract. When set, a VM renders a new shared snippet
   `clusters/_shared/cloud-init/use-dns.conf.tftpl` into
   `/etc/systemd/resolved.conf.d/99-centralized-dns.conf` (`DNS=<dns_ip>`), pointing its
   resolver at AdGuard Home at first boot. Empty default keeps `just up <cluster>` turnkey.

3. **`just up-connected` re-ordered**: `centralized_dns` → (health-gate on AdGuard
   answering) → `centralized_logging` → `centralized_monitoring` → consumers → hot-push
   (DNS-hub self-telemetry + Prometheus scrape targets, including the DNS VM's exporters).

4. **Host-side uv CLIs** `adguard_cli.py` and `unbound_cli.py` + hermetic
   pytest-httpserver suites, auto-discovered by `just verify-api` (both expose `check`).

5. **Two-layer tests** mirroring the repo: hermetic `tests/tofu/*.tftest.hcl`
   (mock_provider, plan) and live `tests/testinfra/` over SSH.

### Why host-level + systemd (not Docker)

The reference repo installs all three components as native services (LaunchDaemons on
macOS). On Ubuntu the equivalents are: AdGuard Home's official install script (registers
an `AdGuardHome.service` systemd unit), `apt install unbound` (stock `unbound.service`),
and exporter binaries wrapped in hand-written systemd units with `EnvironmentFile`. This
matches the user's explicit requirement and keeps the DNS path off the Docker daemon
(lower latency, one fewer moving part for a `:53` critical service). The
`clusters/centralized_pki` cluster is the reference for hand-rolled systemd exporters via
`/usr/local/sbin/install-exporter.sh`.

### Port 53 contention (critical)

Ubuntu ships `systemd-resolved` bound to `127.0.0.53:53`. AdGuard Home binds `0.0.0.0:53`,
which collides on the loopback stub. Cloud-init must, **after** all apt work that needs
name resolution completes: write `/etc/systemd/resolved.conf.d/00-adguard.conf` with
`DNSStubListener=no`, restart `systemd-resolved`, then start AdGuard Home. Ordering is
load-bearing — freeing `:53` before the box's own resolution is re-homed to `127.0.0.1`
(AdGuard) would break mid-boot apt. Sequence on the DNS VM:

```
apt install (resolved still active) → configure+start unbound (127.0.0.1:5335)
  → seed AdGuardHome.yaml → free :53 (DNSStubListener=no) → start AdGuard Home
  → point the VM's own resolv.conf at 127.0.0.1 (its own AdGuard) → start exporters
```

## Relevant Files

### Existing files to read / imitate

- `clusters/centralized_pki/main.tf`, `variables.tf`, `outputs.tf`, `providers.tf`,
  `versions.tf`, `terraform.tfvars` — the reference **single-signal → multi-VM**
  cross-cluster consumer. Copy its `local.flags` threading, `ship_logs`/`push_otlp`
  gating, `syslog_client_conf`/`otel_agent_conf` locals, and `hosts`/`enabled_flags`/
  `web_urls` outputs. `centralized_dns` is simpler (one VM) but the same shape.
- `clusters/centralized_pki/cloud-init/ca.yaml.tftpl` — the canonical consumer cloud-init:
  gated `write_files`/`runcmd` blocks for `install-exporter.sh`, `node_exporter`,
  `syslog_client_conf`, `otel_agent_conf`, plus the `timedatectl set-timezone` runcmd.
  `centralized_dns`'s single cloud-init is modeled directly on this.
- `clusters/_shared/cloud-init/syslog-client.conf.tftpl`,
  `otel-agent-config.yaml.tftpl`, `install-node-exporter.sh` — the byte-identical shared
  snippets. Reused verbatim; `use-dns.conf.tftpl` is added alongside them.
- `Justfile` (recipes `up`, `up-connected` lines 117-169, `prune`, `check`, `verify`,
  `verify-api`, `open`, `verify-connected`) — the orchestration to extend.
- `clusters/centralized_monitoring/scripts/_obs_common.py`,
  `openobserve_cli.py` — the uv single-file CLI pattern (typer + rich + httpx,
  `tofu output` server resolution, `CheckReport`, `check` exit code). `adguard_cli.py`
  and `unbound_cli.py` follow this shape.
- `clusters/centralized_monitoring/tests/openobserve/` — the hermetic CLI test layout
  (pytest-httpserver, `pythonpath = ["../../scripts"]`).
- `specs/cross-cluster.md`, `specs/centralized_pki.md`, `specs/cli-openobserve.md`,
  `specs/centralized_netbox.md` (for the async-oneshot boot pattern) — companion specs.
- `~/dev/bossjones/adguardhome-unbound-macos-setup/install.sh` — the authoritative
  install/config recipe for all three components (Unbound hardened `server:` block,
  AdGuard official installer, exporter env file + service wrapper). **Adapt macOS →
  Ubuntu**: LaunchDaemon → systemd unit, `brew install unbound` → `apt install unbound`,
  `sudo brew services` → `systemctl`.
- `~/dev/bossjones/adguardhome-unbound-macos-setup/tools/adguardctl/` — the async AdGuard
  control-API client (`client.py`, `api.py`, `models.py`, `cli/*.py`). Source of endpoint
  paths (`/control/status`, `/control/stats`, `/control/dns_info`, `/control/filtering/status`,
  `/control/querylog`) and auth semantics (Basic → cookie-login fallback) that
  `adguard_cli.py` ports into a single-file CLI.
- `~/dev/bossjones/adguardhome-unbound-macos-setup/tools/adguardctl/docker/adguardhome/AdGuardHome.yaml`
  — the **sanitized seed config** to base the rendered `AdGuardHome.yaml.tftpl` on
  (users, `upstream_dns: [127.0.0.1:5335]`, filters, `blocked_hosts`, `schema_version`).
- `~/dev/bossjones/adguardhome-unbound-macos-setup/tools/adguardctl/docker/unbound/unbound.conf`
  — the hardened Unbound config to base the rendered drop-in on (adapt interface back to
  `127.0.0.1:5335`, add `remote-control` unix socket for `unbound_exporter`).

### New Files

Cluster root:
- `clusters/centralized_dns/main.tf` — locals, `local_file.server_ci`, `multipass_instance.server`.
- `clusters/centralized_dns/variables.tf` — `name_prefix`, `image`, `ssh_pubkey*`, sizing,
  exporter flags, `adguard_user`/`adguard_password`/`adguard_password_hash`, DNS tuning
  vars, and the cross-cluster contract (`dns_server`, `log_shipping_target`,
  `openobserve_endpoint`, `openobserve_org`, `openobserve_password`, `enable_node_exporter`).
- `clusters/centralized_dns/outputs.tf` — `server_ipv4`, `hosts`, `enabled_flags`,
  `web_urls`, `adguard_url`, `adguard_credentials` (sensitive; dev-throwaway, mirrors the
  NetBox token pattern).
- `clusters/centralized_dns/providers.tf`, `versions.tf`, `terraform.tfvars` — copy from pki.
- `clusters/centralized_dns/DEFAULT_PASSWORDS.md`, `README.md`, `USAGE.md`.

Cloud-init:
- `clusters/centralized_dns/cloud-init/server.yaml.tftpl` — the one VM's cloud-init.
- `clusters/centralized_dns/cloud-init/adguard/AdGuardHome.yaml.tftpl` — rendered seed.
- `clusters/centralized_dns/cloud-init/unbound/unbound.conf.tftpl` — rendered drop-in
  (written to `/etc/unbound/unbound.conf.d/centralized-dns.conf`).

Shared (deliberate `_shared` exception, like the syslog/otel snippets):
- `clusters/_shared/cloud-init/use-dns.conf.tftpl` — `resolved.conf.d` drop-in rendered
  with `dns_ip`; used by **every** cluster (added to their cloud-init as a gated block).

Scripts (uv single-file CLIs + shared helper):
- `clusters/centralized_dns/scripts/_dns_common.py` — tofu-output resolution + `CheckReport`
  (cluster-local copy of the `_obs_common.py` shape; parses `server_ipv4`/`enabled_flags`).
- `clusters/centralized_dns/scripts/adguard_cli.py` — AdGuard Home control-API CLI.
- `clusters/centralized_dns/scripts/unbound_cli.py` — Unbound-via-exporter CLI.

Tests:
- `clusters/centralized_dns/tests/tofu/sizing_and_render.tftest.hcl`,
  `cross_cluster.tftest.hcl` — hermetic.
- `clusters/centralized_dns/tests/testinfra/{conftest.py,test_dns.py,test_services.py,test_metrics.py,test_cross_cluster.py,pyproject.toml}`.
- `clusters/centralized_dns/tests/adguard/`, `tests/unbound/`, `tests/dns_common/` — hermetic CLI suites.

Doc / orchestration edits:
- `Justfile` — re-order `up-connected`; add `adguard-check`/`unbound-check`/`dns-check`
  convenience recipes.
- `specs/cross-cluster.md` — document the new `dns_server` signal + ordering.
- `CLAUDE.md` (root, "Clusters" section) — add `centralized_dns` and its recipes.

## Implementation Phases

### Phase 1: Foundation

The shared `dns_server` contract and the new shared snippet, so every cluster (existing +
new) can opt into using the DNS hub before the DNS cluster itself is wired into orchestration.

- Add `clusters/_shared/cloud-init/use-dns.conf.tftpl`.
- Add the `dns_server` variable + gated cloud-init block to **every existing cluster's**
  variables + cloud-init (`centralized_logging`, `centralized_monitoring`,
  `centralized_pki`, `centralized_netbox`, `centralized_unifi`), mirroring how
  `log_shipping_target` is threaded. Default `""` = no change to turnkey `just up`.

### Phase 2: Core Implementation

The `centralized_dns` cluster itself: OpenTofu root module, cloud-init that installs and
configures Unbound + AdGuard Home + exporters host-level via systemd, and the seeded
AdGuard config. Then the host-side CLIs.

### Phase 3: Integration & Polish

Re-order `up-connected`, add the DNS-hub self-telemetry hot-push, extend `verify-connected`,
write all tests, update docs.

## Step by Step Tasks

IMPORTANT: Execute every step in order, top to bottom.

### 1. Shared `dns_server` snippet + contract

- Create `clusters/_shared/cloud-init/use-dns.conf.tftpl`:
  ```
  # Managed by OpenTofu — SHARED cross-cluster snippet (clusters/_shared/cloud-init).
  # Points this VM's stub resolver at the centralized_dns AdGuard Home instance.
  # Dropped into /etc/systemd/resolved.conf.d/; systemd-resolved merges *.conf.
  [Resolve]
  DNS=${dns_ip}
  Domains=~.
  ```
  (`Domains=~.` routes *all* lookups through AdGuard. Keep the image's `FallbackDNS` so a
  DNS-hub outage degrades rather than bricks resolution — document this trade-off: the
  fallback can bypass ad-blocking during an outage.)
- This snippet is rendered with `templatefile(".../use-dns.conf.tftpl", { dns_ip = split(":", var.dns_server)[0] })`
  only when `var.dns_server != ""`.

### 2. Thread `dns_server` into every existing cluster

For each of `centralized_logging`, `centralized_monitoring`, `centralized_pki`,
`centralized_netbox`, `centralized_unifi`:
- Add to `variables.tf`:
  ```hcl
  variable "dns_server" {
    description = "IP (or host[:port]) of the centralized_dns AdGuard Home resolver. Non-empty -> every VM points systemd-resolved at it at first boot. Empty (default) = use the image default resolver."
    type        = string
    default     = ""
  }
  ```
- In `main.tf`, add a local `use_dns = var.dns_server != ""` and
  `dns_resolved_conf = local.use_dns ? templatefile(".../use-dns.conf.tftpl", { dns_ip = split(":", var.dns_server)[0] }) : ""`,
  and pass `dns_server` + `dns_resolved_conf` into every `templatefile()` for the VMs' cloud-init.
- In each VM cloud-init `.tftpl`, add a gated `write_files` block (drop the drop-in) and a
  gated `runcmd` block near the **top** of `runcmd` (before any apt in runcmd), e.g.:
  ```
  %{ if dns_server != "" ~}
    - path: /etc/systemd/resolved.conf.d/99-centralized-dns.conf
      permissions: '0644'
      content: |
        ${indent(6, dns_resolved_conf)}
  %{ endif ~}
  ```
  ```
  %{ if dns_server != "" ~}
    # Cross-cluster DNS — resolve through the centralized_dns AdGuard Home hub.
    - systemctl restart systemd-resolved
  %{ endif ~}
  ```
- Update each cluster's hermetic `tests/tofu/cross_cluster.tftest.hcl` (or `sizing_and_render`)
  with a run asserting the drop-in renders iff `dns_server` is set.

### 3. Scaffold the `centralized_dns` OpenTofu root module

- Copy `providers.tf`, `versions.tf` from `centralized_pki` unchanged.
- `variables.tf`:
  - `name_prefix` default `"centralized-dns"`, `image` default `"24.04"`, `ssh_pubkey*`.
  - `server` sizing object, default `{ cpus = 2, memory = "2G", disk = "20G" }` (DNS +
    exporters are light).
  - `adguard_user` (default `"admin"`), `adguard_password` (sensitive, dev default e.g.
    `"changeme-dns-lab"`), `adguard_password_hash` (bcrypt of that default — precompute
    with `htpasswd -B` / AdGuard's own hash; pin like pki's `authelia_password_hash`).
  - DNS tuning knobs: `blocklists` (`list(string)`, default the reference filter URLs),
    `upstream_unbound` (default `"127.0.0.1:5335"`), `adguard_web_port` (default `3000`).
  - Exporter flags: `enable_node_exporter` (default `true`),
    `enable_process_exporter`/`enable_systemd_exporter` (default `true`, parity with pki).
  - Cross-cluster contract: `dns_server` (default `""` — the DNS VM points at *itself*,
    so this stays empty for this cluster), `log_shipping_target`, `openobserve_endpoint`,
    `openobserve_org`, `openobserve_password` (copy verbatim from pki `variables.tf`).
- `main.tf`:
  - `local.flags` = the exporter flags; `local.enabled_flags = sort([...])`.
  - `local.ship_logs`/`push_otlp`/`syslog_client_conf`/`otel_agent_conf` — copy from pki
    (single VM → one `otel_agent_conf` with `stream_name = "centralized_dns_server"`).
  - `local.adguard_conf = templatefile("cloud-init/adguard/AdGuardHome.yaml.tftpl", {...})`
    and `local.unbound_conf = templatefile("cloud-init/unbound/unbound.conf.tftpl", {})`.
  - `local_file.server_ci` renders `cloud-init/server.yaml.tftpl`; `multipass_instance.server`.
- `outputs.tf`: `server_ipv4`, `hosts = { server = { name, ipv4 } }`, `enabled_flags`,
  `adguard_url = "http://${ip}:${var.adguard_web_port}"`,
  `adguard_credentials` (sensitive: `{ user, password }`), and `web_urls` (`core` = AdGuard
  UI; `all` = core + enabled `/metrics` at `:9100`, `:9618`, `:9167`, `:9256`, `:9558`).
- `terraform.tfvars` — empty/defaults, like pki.

### 4. Render the Unbound drop-in (`cloud-init/unbound/unbound.conf.tftpl`)

- Base on `install.sh`'s hardened `server:` block AND the docker `unbound.conf`, but:
  - `interface: 127.0.0.1`, `port: 5335`, `access-control: 127.0.0.0/8 allow` +
    `access-control: 0.0.0.0/0 refuse` (only AdGuard on localhost queries it).
  - DNSSEC via `auto-trust-anchor-file: "/var/lib/unbound/root.key"` (apt package ships
    `unbound-anchor`); `root-hints:` pointing at a downloaded `/var/lib/unbound/root.hints`.
  - `qname-minimisation`, `prefetch`, `serve-expired`, hardening flags (copy from reference).
  - `use-syslog: yes` so Unbound logs reach journald/syslog and get shipped.
  - **Add a `remote-control:` block for `unbound_exporter`:**
    ```
    remote-control:
        control-enable: yes
        control-interface: /run/unbound.ctl
    ```
    (unix socket → no TLS certs to manage; the exporter runs as root on the same host.)
- Written to `/etc/unbound/unbound.conf.d/centralized-dns.conf` (Ubuntu's stock
  `unbound.conf` `include:`s `unbound.conf.d/*.conf`).

### 5. Render the AdGuard Home seed (`cloud-init/adguard/AdGuardHome.yaml.tftpl`)

- Base on the sanitized `tools/adguardctl/docker/adguardhome/AdGuardHome.yaml`, changing:
  - `http.address: 0.0.0.0:${adguard_web_port}` (web UI + `/control` API).
  - `users: [ { name: ${adguard_user}, password: ${adguard_password_hash} } ]` (bcrypt).
    Seeding a user means AdGuard skips the setup wizard on first boot.
  - `dns.bind_hosts: [0.0.0.0]`, `dns.port: 53`,
    `dns.upstream_dns: [${upstream_unbound}]` (i.e. `127.0.0.1:5335`),
    `dns.bootstrap_dns: [9.9.9.10, 149.112.112.10]` (to resolve DoH upstream names if ever added).
  - `filters:` rendered from `var.blocklists` (default = the reference filter set,
    including HaGeZi + the bossjones blocklist).
  - Keep `querylog.enabled: true`, `statistics.enabled: true`, `blocked_hosts`.
  - Pin `schema_version` to the value matching the AdGuard version installed (verify at
    implementation; AdGuard migrates forward on first run).
- Rendered to `/opt/AdGuardHome/AdGuardHome.yaml` **before** the official installer runs,
  so the installer/binary picks it up (`AdGuardHome -w /opt/AdGuardHome`).

### 6. Write the DNS VM cloud-init (`cloud-init/server.yaml.tftpl`)

Model on `centralized_pki/cloud-init/ca.yaml.tftpl`. Structure:

- `#cloud-config` header; `package_update: true`, `package_upgrade: false`; `timezone: Etc/UTC`;
  `ntp: systemd-timesyncd`; `ssh_authorized_keys: [${ssh_pubkey}]`.
- `packages:` — `curl tar vim htop jq unbound dnsutils` (`dnsutils` for `dig`/`unbound-control`).
- `write_files:`:
  - `/etc/unbound/unbound.conf.d/centralized-dns.conf` ← `${indent(6, unbound_conf)}`.
  - `/opt/AdGuardHome/AdGuardHome.yaml` ← `${indent(6, adguard_conf)}` (perms `0644`; the
    installer's own daemon user reads it).
  - `/etc/systemd/resolved.conf.d/00-adguard.conf` with `[Resolve]\nDNSStubListener=no`.
  - `/usr/local/sbin/install-exporter.sh` (copy the generic installer from pki cloud-init).
  - `/etc/adguard-exporter/adguard-exporter.env` (perms `0600`):
    `ADGUARD_SERVERS=http://127.0.0.1:${adguard_web_port}`, `ADGUARD_USERNAMES=${adguard_user}`,
    `ADGUARD_PASSWORDS=${adguard_password}`, `INTERVAL=30s`, `BIND_ADDR=:9618`.
  - `/etc/systemd/system/adguard-exporter.service` (EnvironmentFile the above; ExecStart
    `/usr/local/bin/adguard-exporter`; `Restart=always`).
  - `/etc/systemd/system/unbound_exporter.service` (ExecStart
    `/usr/local/bin/unbound_exporter -unbound.host unix:///run/unbound.ctl`;
    `After=unbound.service`; `Restart=always`).
  - Gated `syslog_client_conf` + `otel_agent_conf` blocks (copy from pki, `%{ if ... != "" }`).
- `runcmd:` **in this order** (ordering is load-bearing — see "Port 53 contention"):
  1. `timedatectl set-timezone Etc/UTC` (Multipass timezone override guard, per `specs/ntp.md`).
  2. **Unbound**: download root hints + trust anchor
     (`unbound-anchor -a /var/lib/unbound/root.key || true`;
     `curl -fsSL https://www.internic.net/domain/named.root -o /var/lib/unbound/root.hints || true`),
     `unbound-checkconf`, `systemctl enable --now unbound`, wait until
     `dig @127.0.0.1 -p 5335 example.com +short` answers.
  3. **AdGuard Home**: run the official installer
     `curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v` (installs to `/opt/AdGuardHome`, registers systemd unit; picks up the seeded `AdGuardHome.yaml`).
  4. **Free `:53`**: `systemctl restart systemd-resolved` (now `DNSStubListener=no`),
     `systemctl restart AdGuardHome`, wait until `dig @127.0.0.1 example.com +short` answers on `:53`.
  5. **Re-home the box's own resolver**: point `/etc/resolv.conf` → `127.0.0.1` (its own
     AdGuard) via a resolved drop-in `DNS=127.0.0.1` + `systemctl restart systemd-resolved`.
  6. **node_exporter** (gated `enable_node_exporter`) via `install-exporter.sh`.
  7. **adguard-exporter**: download the release binary (arch-aware, from
     `github.com/henrywhitaker3/adguard-exporter/releases`, pin a version e.g. `v1.2.1`;
     fall back to `go install` if no asset), `systemctl daemon-reload`,
     `systemctl enable --now adguard-exporter`.
  8. **unbound_exporter**: install Go (`apt-get install -y golang-go`) and
     `GOBIN=/usr/local/bin go install github.com/letsencrypt/unbound_exporter@latest`
     (prefer a prebuilt linux/arm64 release asset if one exists — verify at implementation),
     `systemctl enable --now unbound_exporter`.
  9. Gated `syslog-ng` + `otelcol-contrib` install/restart blocks (copy from pki).
  10. (Gated) `process-exporter`/`systemd_exporter` for parity.
- `final_message: "AdGuard Home ready on :53 (UI :${adguard_web_port}); Unbound upstream on 127.0.0.1:5335"`.

**Async-boot consideration**: AdGuard's installer + the Go build for `unbound_exporter`
may push first boot toward the Multipass 300s launch window (see `specs/centralized_netbox.md`).
If `just up centralized_dns` times out with an orphaned VM, convert the AdGuard + exporter
install into a systemd oneshot launched `--no-block` (the NetBox `netbox-stack.service`
pattern) so `multipass launch` returns while provisioning finishes in the background. Start
with inline `runcmd`; fall back to the oneshot if timeouts appear.

### 7. `adguard_cli.py` (host-side control-API CLI)

- uv single-file (`#!/usr/bin/env -S uv run --script`, PEP 723 deps `typer rich httpx`),
  modeled on `openobserve_cli.py` + `_dns_common.py`.
- Resolve the server from `tofu output` (`server_ipv4` + `adguard_web_port`) or `--server-url`;
  credentials via flag > env (`ADGUARD_USER`/`ADGUARD_PASSWORD`) > tofu `adguard_credentials`.
- Port the essential subset of `tools/adguardctl` (single-file, not the full package):
  `status` (`GET /control/status`), `stats` (`GET /control/stats`),
  `upstreams`/`dns-info` (`GET /control/dns_info`), `filters` (`GET /control/filtering/status`),
  `querylog` (`GET /control/querylog`), and `check`.
- `check` (nonzero on failure): AdGuard `/control/status` is reachable + `running: true`,
  `dns_addresses` non-empty, and `upstream_dns` contains `127.0.0.1:5335` (i.e. Unbound wired).
- Auth: Basic first, fall back to cookie login (`POST /control/login`) on 401/403 — same
  semantics as `adguardctl/client.py`.

### 7a. DNS rewrites (custom records) + `just set-dns` — fleet hostname registration

`adguard_cli.py` also carries **write** commands over AdGuard's `/control/rewrite/*` API so the
fleet's service hostnames resolve fleet-wide (replacing the per-machine `/etc/hosts` edits that
`centralized_pki/USAGE.md` describes). A shared `_post(c, path, json_body)` helper mirrors `_get`
(reuses the logged-in `Ctx.client()`), and the commands are:

- `rewrite-list` — `GET /control/rewrite/list`.
- `rewrite-add DOMAIN ANSWER` / `rewrite-delete DOMAIN ANSWER` — the raw additive add/delete.
- `rewrite-set DOMAIN ANSWER` — **idempotent**: lists, deletes every existing row for `DOMAIN`,
  then adds (AdGuard's `add` is additive/allows dupes, so a true "set" must delete first).
- `rewrite-sync --file PATH|-` — reads a `{hostname: answer}` JSON object (stdin via `-`) and
  applies `rewrite-set` per entry; prints an added/updated/unchanged summary. `--prune` (default
  off) also removes AdGuard rows absent from the payload. Re-running is safe; IP churn after a
  `recreate` overwrites the old answer.

**Data source (vendored, per-cluster).** Every cluster declares a `variable "domain"` (default
`lab.theblacktonystark.com`, duplicated like `dns_server`) and a `dns_records` output — a
`{ "<service>.${var.domain}" = <role>.ipv4 }` map built from its own VM IPs. Conditional records
(`coroot.<domain>` on the logging k0s node, `diode.<domain>` on netbox) are gated with
`merge(..., var.enable_x ? {...} : {})`, matching the record's `enable_*` install flag.

**Recipes.** `just set-dns <cluster>` pipes one cluster's `tofu output -json dns_records` into
`rewrite-sync --file -`; `just set-dns-all` merges every up cluster's records (`jq -s 'reduce
.[] as $x ({}; . * $x)'`, clusters that aren't up contribute `{}`) and syncs once; `just
verify-dns` `dig`s each record against the AdGuard IP and exits nonzero on a mismatch. `just
up-connected` runs `set-dns-all` as its **final** step (after the Prometheus hot-push), so records
register only once the whole fleet is up.

### 8. `unbound_cli.py` (host-side, via the exporter)

- uv single-file (`typer rich httpx`). Unbound has no HTTP API, so this scrapes the
  `unbound_exporter` `:9167/metrics` endpoint (host-side HTTP, like the other CLIs).
- Subcommands: `stats` (parse + render cache hits/misses, queries, memory as a rich table),
  `check` (nonzero on failure): `:9167/metrics` responds AND `unbound_up 1` (exporter could
  reach Unbound's control socket) AND `unbound_queries_total` present.
- `--server-url` / tofu resolution identical to `adguard_cli.py`.

### 9. `_dns_common.py`

- Cluster-local copy of the `_obs_common.py` shape: `run_tofu_output`, `parse_tofu_output`
  (returns `server_ipv4` + `enabled_flags`), `default_chdir`, `http_get_json`, `poll`,
  `CheckReport` (accumulator + `CHECK_FAIL_EXIT`). Stdlib-only; typer/rich stay in the CLIs.

### 10. Hermetic tofu tests (`tests/tofu/`)

- `sizing_and_render.tftest.hcl` (`mock_provider "multipass" {}`, `command = plan`):
  - `server` VM has `cpus = 2`, `memory = "2G"`.
  - `local_file.server_ci.content` contains: the official AdGuard install URL; the seeded
    `upstream_dns` = `127.0.0.1:5335`; `${adguard_user}` in `AdGuardHome.yaml`;
    `control-interface: /run/unbound.ctl`; `DNSStubListener=no`; the `adguard-exporter`
    + `unbound_exporter` systemd units; `install-exporter.sh ... node_exporter` when
    `enable_node_exporter = true`.
- `cross_cluster.tftest.hcl`:
  - With `log_shipping_target = "10.0.0.9:514"` → cloud-init contains `d_central` + the IP;
    empty → it does not (mirror pki).
  - Same for `openobserve_endpoint`.
  - `dns_server` is intentionally empty for this cluster (it points at itself) — assert the
    seeded config sets the box's own resolver to `127.0.0.1`, not an external `dns_server`.

### 11. Live testinfra tests (`tests/testinfra/`)

- `conftest.py` — copy pki's: read `hosts` output, build SSH testinfra hosts, parametrize on
  `enabled_flags`.
- `test_services.py` — `AdGuardHome`, `unbound`, `adguard-exporter`, `unbound_exporter`,
  `node_exporter` systemd units are `active` (skip process/systemd exporter when flag off).
- `test_dns.py` — from the host or over SSH: `dig @<ip> example.com +short` returns an A
  record (AdGuard→Unbound path works); `dig @127.0.0.1 -p 5335 example.com` works on the VM;
  a known ad domain (e.g. `doubleclick.net`) is blocked (returns `0.0.0.0`/NXDOMAIN).
- `test_metrics.py` — `:9100`, `:9618`, `:9167` `/metrics` respond; `:9618` exposes an
  `adguard_*` metric and `:9167` exposes `unbound_*`.
- `test_cross_cluster.py` — copy pki's: when `log_shipping_target`/`openobserve_endpoint`
  set, assert the drop-ins exist + the agents run.

### 12. Hermetic CLI tests (`tests/adguard/`, `tests/unbound/`, `tests/dns_common/`)

- Mirror `tests/openobserve/`: `pyproject.toml` with `pythonpath = ["../../scripts"]`,
  pytest-httpserver stubbing the AdGuard `/control/*` endpoints and the `:9167/metrics`
  text, asserting the CLIs render + `check` returns 0/nonzero correctly.

### 13. Re-order `just up-connected` (DNS first) + DNS self-telemetry hot-push

Rewrite the `up-connected` recipe (`Justfile` ~117-169) to:

```sh
dns=centralized_dns; logging=centralized_logging; monitoring=centralized_monitoring

# 0. DNS hub FIRST — pure :53 sink. No telemetry targets yet (hubs don't exist).
just up "$dns"
dns_ip="$(tofu -chdir={{cluster_root}}/$dns output -raw server_ipv4)"
# health-gate: do NOT wire anyone until AdGuard actually answers, else dependent VMs
# switch their resolver at boot and cannot resolve archive.ubuntu.com.
until dig +time=2 +tries=1 @"$dns_ip" example.com >/dev/null 2>&1; do sleep 5; done

# 1. logging hub — now resolves via DNS.
jq -n --arg dns "$dns_ip" '{dns_server:$dns}' > .../$logging/.cross-cluster.auto.tfvars.json
just up "$logging"; log_ip=...

# 2. monitoring hub — resolves via DNS + self-ships OS logs.
jq -n --arg dns "$dns_ip" --arg log "$log_ip:514" '{dns_server:$dns, log_shipping_target:$log}' > .../$monitoring/...
just up "$monitoring"; mon_ip=...

# 3. consumers — dns_server + log_shipping_target + openobserve_endpoint, single boot.
for c in ...: jq -n '{dns_server, log_shipping_target, openobserve_endpoint}'; just up "$c"; accumulate :9100 targets

# 3b. add the DNS hub's OWN exporters to the scrape set (:9100, :9618, :9167).
targets += [{job:centralized-dns-server-node,ip:$dns_ip,port:9100},
            {job:centralized-dns-adguard,ip:$dns_ip,port:9618},
            {job:centralized-dns-unbound,ip:$dns_ip,port:9167}]

# 4. DNS-hub self-telemetry HOT-PUSH (mirrors the Prometheus scrape hot-push; no recreate):
#    the DNS VM booted before the hubs, so wire its log shipping now.
jq -n --arg log "$log_ip:514" --arg oo "$mon_ip:5080" '{log_shipping_target:$log, openobserve_endpoint:$oo}' \
  > .../$dns/.cross-cluster.auto.tfvars.json
tofu -chdir=.../$dns apply -auto-approve      # content-only change: re-renders .rendered/, NO VM recreate
# scp the freshly-rendered syslog-ng + otel drop-ins onto the running DNS VM and (re)start the agents.
# (The DNS cloud-init installs syslog-ng + otelcol-contrib unconditionally at first boot so this is a
#  scp+restart, exactly like the Prometheus hot-push — see note below.)

# 5. Prometheus scrape-target hot-push (existing step, now including the DNS exporters).
```

Note for step 4: so the hot-push is a clean `scp + restart` (not an apt install over SSH),
the DNS cloud-init should **install `syslog-ng` + `otelcol-contrib` unconditionally** at
first boot (writing their configs only when the targets are set), and `main.tf` should emit
the rendered drop-ins as `local_file`s (e.g. `.rendered/10-ship.conf`, `.rendered/otel-config.yaml`)
so step 4's targeted re-apply materializes them on disk for `scp`. This keeps the DNS IP
stable (never recreated) while still shipping its logs. Health-gate `dig` needs `dig` on the
host (macOS ships it); fall back to `nslookup` if absent.

### 14. Extend `verify-connected` + convenience recipes

- In `verify-connected`, add: after the existing checks, assert a consumer VM resolves via
  AdGuard — SSH to the pki services VM and check
  `resolvectl status | grep <dns_ip>` (or `grep <dns_ip> /run/systemd/resolve/resolv.conf`),
  and `just prometheus-query centralized_monitoring 'up{job=~"centralized-dns.*"}'`.
- Add `adguard-check`, `unbound-check`, and a `dns-check` (runs both) recipe, mirroring
  `grafana-check` etc. `just verify-api centralized_dns` already auto-discovers both CLIs
  (both expose `check`, neither is a `_`-prefixed helper or `heimdall_cli`).

### 15. Docs

- `specs/cross-cluster.md` — add the `dns_server` row to the signal table + the "DNS up
  FIRST" ordering note + the self-telemetry hot-push.
- Root `CLAUDE.md` "Clusters" section — add `centralized_dns` (one-line description + that
  it comes up first in `up-connected`).
- `clusters/centralized_dns/{README.md,USAGE.md,DEFAULT_PASSWORDS.md}` — usage + the dev
  AdGuard admin creds (mirror the NetBox token disclosure: throwaway lab only).

### 16. Validate

- Run the hermetic gate for the new cluster and every cluster touched in step 2:
  `just check centralized_dns` (+ `just check <each edited cluster>`).
- `tofu fmt -recursive` across `clusters/`.
- Ruff + `ty` on the new scripts (the PostToolUse validators run these automatically).
- Live: `just up centralized_dns` → `just verify centralized_dns` → `just verify-api centralized_dns`.
- Fleet: `just up-connected` → `just verify-connected`.

## Testing Strategy

Two-layer split, mirroring the rest of the repo (`specs/cross-cluster.md` §Testing):

- **Hermetic** (`just check centralized_dns`, no VMs): `mock_provider "multipass" {}` +
  `command = plan`. Assert VM sizing and that the rendered cloud-init contains the AdGuard
  install, the `127.0.0.1:5335` upstream wiring, `DNSStubListener=no`, the Unbound
  `control-interface` socket, both exporter systemd units, and the `dns_server`/log/otel
  gating (present iff the corresponding var is set). CLI logic is covered hermetically with
  pytest-httpserver stubbing AdGuard's `/control/*` and the exporter `/metrics` text.
- **Live** (`just verify centralized_dns`, `just verify-api centralized_dns`,
  `just verify-connected`): testinfra over SSH asserts the five systemd units are active,
  `:53`/`:5335` resolve, a blocklisted domain is blocked, all three `/metrics` respond, and
  (fleet) a consumer VM's resolver points at the DNS hub while Prometheus scrapes it.

Edge cases to cover: AdGuard install exceeding the 300s launch window (fall back to the
`--no-block` systemd oneshot pattern); `unbound_exporter` with no prebuilt arm64 asset
(`go install` fallback); a DNS-hub outage (resolver must degrade via `FallbackDNS`, not
brick the box); seeded-config schema-version drift (AdGuard migrates forward — pin + verify).

## Acceptance Criteria

- `just up centralized_dns` brings up one VM with AdGuard Home answering on `<ip>:53`,
  Unbound answering on `127.0.0.1:5335`, and AdGuard's upstream set to Unbound — with **no
  interactive setup wizard** (seeded `AdGuardHome.yaml`).
- Both DNS utilities run as **host-level systemd units** (`AdGuardHome.service`,
  `unbound.service`) — no Docker involved in the DNS path.
- `adguard-exporter` (`:9618`), `unbound_exporter` (`:9167`), and `node_exporter` (`:9100`)
  all serve metrics and run as systemd units.
- A known ad/tracker domain is blocked; a normal domain resolves recursively via Unbound.
- `just up-connected` applies **centralized_dns first**, health-gates on AdGuard answering,
  and every other fleet VM (both hubs + all consumers) has its systemd-resolved pointed at
  the AdGuard IP at first boot.
- The DNS VM's own OS + service logs reach OpenObserve (and the syslog-ng collector), and
  its three exporters are scraped by Prometheus — wired via hot-push, with the DNS VM never
  recreated (stable IP).
- `just verify centralized_dns`, `just verify-api centralized_dns`, and `just verify-connected`
  all pass; `just check centralized_dns` (and every cluster edited in step 2) passes hermetically.
- `just open centralized_dns` opens the AdGuard Home UI; `--full` adds the exporter endpoints.

## Validation Commands

- `just check centralized_dns` — hermetic fmt + validate + tofu test (no VMs).
- `tofu -chdir=clusters/centralized_dns fmt -check -recursive` — formatting gate.
- `tofu -chdir=clusters/centralized_dns test -test-directory=tests/tofu` — hermetic render/sizing.
- `just check centralized_logging && just check centralized_monitoring && just check centralized_pki && just check centralized_netbox && just check centralized_unifi` — the `dns_server` thread-through did not break any cluster.
- `uv run clusters/centralized_dns/scripts/adguard_cli.py --help` and `unbound_cli.py --help` — CLIs load.
- `cd clusters/centralized_dns/tests/adguard && uv run pytest -q` (and `tests/unbound`, `tests/dns_common`) — hermetic CLI suites.
- Live (VMs up): `just up centralized_dns && just verify centralized_dns && just verify-api centralized_dns`.
- Fleet (VMs up): `just up-connected && just verify-connected`.

## Notes

- **New libraries**: the CLIs are uv single-file scripts (inline PEP 723 `typer`, `rich`,
  `httpx`) — no repo-level `uv add`. Hermetic CLI test suites depend on `pytest` +
  `pytest-httpserver` (declared in each `tests/<name>/pyproject.toml`, mirroring
  `tests/openobserve/`).
- **Exporters** (confirmed via web search):
  - `adguard-exporter` — `github.com/henrywhitaker3/adguard-exporter`, `:9618`, env vars
    `ADGUARD_SERVERS`/`ADGUARD_USERNAMES`/`ADGUARD_PASSWORDS`/`INTERVAL`/`BIND_ADDR`;
    Grafana dashboard ID **20799**. (The macOS `install.sh` pins `v1.2.1`; confirm the
    latest linux/arm64 release asset at implementation.)
  - `unbound_exporter` — `github.com/letsencrypt/unbound_exporter`, `:9167`, connects to
    Unbound's control socket (`-unbound.host unix:///run/unbound.ctl`) which requires
    `remote-control: control-enable: yes` in `unbound.conf`. Go binary — prefer a prebuilt
    release asset; else `go install ...@latest`.
- **AdGuard admin credentials** are a **dev-throwaway** pinned password (plaintext for the
  exporter/CLI, bcrypt hash for the seeded config) — exported via `tofu output`
  (`adguard_credentials`, sensitive) on purpose, exactly like the NetBox lab token. Do NOT
  copy these to a real deployment; override via `TF_VAR_adguard_password` +
  `TF_VAR_adguard_password_hash` (regenerate the bcrypt hash when changing the password).
- **`_shared` exception**: `use-dns.conf.tftpl` joins the syslog/otel/node-exporter snippets
  as a deliberate, documented break from strict per-cluster vendoring — the `_shared/`
  prefix keeps it out of the `clusters/*/` recipe globs (which skip dirs without `main.tf`).
- **The `pre_tool_use` hook** matches substrings, so avoid literal `rm ` / `.env` tokens in
  commands while implementing (per root `CLAUDE.md` "Working fast" notes); the exporter env
  file is fine as a written artifact — just don't `cat`/`grep` it with the literal token.
- **Editing cloud-init requires `just recreate`**, not `just up` — but recreating the DNS
  hub churns its IP and breaks every dependent VM's resolver. During iteration, patch
  `/opt/AdGuardHome/AdGuardHome.yaml` / the unbound drop-in over SSH and
  `systemctl restart` (per the "Iterate on cloud-init without a full recreate" note), then
  fold the fix back into the `.tftpl`.
```
