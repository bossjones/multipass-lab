# Spec: internal-CA trust + Phase 2 TLS + fleet DNS auto-registration (combined)

**Status:** implemented on `feature-pki-and-dns` (merges `feature-pki-distribute` +
PR #28 `feature-set-dns-records`). This spec is the single source of truth for how the lab's
internal CA, TLS termination, and DNS auto-registration fit together. It **supersedes** the
DNS-registration halves of `specs/internal-ca.md` §Phase 2 and `specs/set-dns.md` (kept for
history; the retired `dns_rewrites`/`dns-register` mechanism is documented as removed below).

## Context

Two parallel branches each solved half of "reach lab services by a real hostname over HTTPS":

- `feature-pki-distribute` gave every cluster an `internal_ca_cert` trust anchor and made
  `centralized_monitoring` **serve** internal-CA TLS on `:443` at `<svc>.<domain>`. To make those
  hostnames resolve it added a `dns_rewrites` var (baked into `AdGuardHome.yaml`) + a
  `just dns-register` recipe (scp the rendered config + restart AdGuard).
- PR #28 built the **general** fleet DNS-registration machinery: a per-cluster `dns_records`
  output, idempotent `adguard_cli rewrite-*` commands over AdGuard's REST API, and
  `just set-dns` / `set-dns-all` / `verify-dns`. It also hardened `up-connected` and shipped a
  journalctl provisioning-triage system + several boot-race fixes.

The TLS feature was effectively inert without a DNS mechanism, and its bespoke `dns_rewrites`
mechanism duplicated PR #28's more general one. **Decision: adopt PR #28's DNS machinery as
canonical and retire `dns_rewrites`/`dns-register`.** Monitoring's `dns_records` already maps the
TLS hostnames to the server IP, so `set-dns-all` makes `grafana.<domain>` etc. resolve with no
TLS-specific DNS code.

## Layers

### 1. Trust anchor (Phase 0/1 — `centralized_pki`)
- `scripts/init_ca.py generate` **persists** step-ca's root + intermediate into a gitignored
  `ca-material.auto.tfvars` + `.ca/root_ca.crt`. The root is **static** — it does not depend on the
  CA VM being up — so any cluster can trust it at first boot regardless of ordering.
- Every cluster accepts `internal_ca_cert` (PEM, empty default). Non-empty → cloud-init drops it
  into `/usr/local/share/ca-certificates/` + runs `update-ca-certificates` at first boot (the same
  gated `write_files` idiom as `dns_server`).
- `just up-connected` injects the pinned root fleet-wide (from `.ca/root_ca.crt`); `just trust-ca
  <cluster>` / `trust-ca-all` hot-push trust to running VMs; `just trust-ca-macos` trusts it on the
  Mac (System keychain + Firefox NSS).

### 2. TLS termination (Phase 2 — `centralized_monitoring`, DONE)
- `use_internal_tls` (default off) makes the monitoring server issue a Traefik leaf from step-ca at
  first boot via the shared `clusters/_shared/cloud-init/issue-cert.sh.tftpl` (JWK `admin`
  provisioner + a 12h renew timer), then front Grafana/Prometheus/Alertmanager/OpenObserve/
  Uptime-Kuma on `:443` at `<svc>.<domain>`. **Additive** — the plain `http://IP:port` publishes
  stay up.
- Needs `ca_ip` + `stepca_ca_password` (must match `centralized_pki`'s) + `domain`. Off for a plain
  `just up`; wired by `INTERNAL_TLS=1 just up-connected` when the CA VM is up.
- Other clusters (logging, netbox, dns, unifi) are Phase 2 **TODO** (see `specs/internal-ca.md` for
  priority order).

### 3. DNS auto-registration (canonical, all clusters)
- Every cluster has a `domain` var (default `lab.theblacktonystark.com`) and a **`dns_records`**
  output: `{ "<svc>.<domain>" = <vm-ipv4> }`, vendored per-cluster (each owns its naming, mirroring
  `hosts`/`web_urls`). Monitoring's maps `grafana./prometheus./alertmanager./openobserve./uptime.` →
  server IP; conditional records (`coroot.`, `diode.`) are gated on their feature flags.
- `clusters/centralized_dns/scripts/adguard_cli.py` exposes `rewrite-list/add/delete/set/sync` over
  AdGuard's `/control/rewrite/*` API. `rewrite-sync` is **idempotent** (deletes stale rows for a
  domain, re-adds; safe under IP churn).
- `just set-dns <cluster>` reads that cluster's `dns_records` and `rewrite-sync`s it. `just
  set-dns-all` merges every up cluster's records (clusters that aren't up contribute `{}`) and syncs
  in one call. `just verify-dns` `dig`s each record against the hub and asserts the answer.
- AdGuard's seeded `AdGuardHome.yaml` starts with `rewrites: []` at boot; `set-dns` writes rewrites
  in at runtime over REST (no recreate, no restart). The old boot-baked `dns_rewrites` templating is
  gone.

### Retired (do not reintroduce)
- `var.dns_rewrites` on `centralized_dns`, its `AdGuardHome.yaml.tftpl` templating, and the
  `dns_rewrites_off_by_default` / `dns_rewrites_render_records` tofu tests.
- The `just dns-register` recipe. Use `just set-dns <cluster>` instead.

## Orchestration — `INTERNAL_TLS=1 just up-connected`

One unioned recipe (the two branches' rewrites merged). Sequence:

0. **DNS hub first** — `centralized_dns` (pure `:53` sink) boots with the CA trust anchor; health-gate
   waits until AdGuard actually answers before wiring anyone.
1. **logging hub** — `dns_server` + `internal_ca_cert` + `enable_coroot: true`.
2. **monitoring hub** — `dns_server` + `log_shipping_target` + `internal_ca_cert`, **plus `tls_json`**
   (`use_internal_tls`/`ca_ip`/`domain`/`stepca_ca_password`) merged in *before* its `just up`
   (leaf issuance is cloud-init-gated, so it must be set at create time). `tls_json` is `{}` unless
   `INTERNAL_TLS` is set **and** `centralized_pki`'s `ca_ipv4` is available.
3. **consumers** — every other cluster in one boot with all hub IPs + CA trust; netbox gets
   `enable_discovery: true`. Accumulates each VM as a Prometheus scrape target.
4. **DNS-hub self-telemetry hot-push** — the DNS VM booted before the hubs, so its shipper/otel
   drop-ins are hot-pushed now (`_hot-push-cross-cluster`; content-only re-apply, no recreate).
5. **Prometheus scrape hot-push** — discovered targets scp'd into the running monitoring server
   (preserving `tls_json` + `internal_ca_cert` in the content-only re-apply so TLS state survives).
6. **`just set-dns-all`** (DEAD LAST) — registers every up cluster's `dns_records` into AdGuard,
   including monitoring's TLS hostnames. `rc`-tracked; a loud `FAILED` summary + nonzero exit on any
   step failure.

`just refresh-cross-cluster` re-discovers the 3 hub IPs, rewrites every wired cluster's tfvars,
content-only re-applies + hot-pushes, and re-runs `set-dns-all` — for recovering after a hub
recreate churns its IP.

## Feedback loop / provisioning triage

Live bring-ups are watched in real time rather than inspected only at the end:

- **`tools/system_debug.py`** (`/system-debug` / `just system-debug <cluster> [role]`): SSHes into
  the VM(s), sweeps `cloud-init status` + `otelcol-contrib` + any `systemctl --failed` unit + a
  `journalctl -p err` boot sweep, and **highlights** smoking-gun lines. Retries ×3 with exponential
  backoff, early-exits once healthy. Exit `0` healthy / `2` issues / `3` unreachable / `4` not-up.
  Shells out to `ssh`/`tofu` (never a Python socket) so it dodges the macOS Local-Network block.
  Pure parsing/policy in `tools/_system_debug_core.py` (hermetically tested in `tools/tests/`).
- **Background journalctl monitor** (`just tail-log <cluster> <role>`) — once SSH answers on a
  freshly-launched VM, tail its journal live (`journalctl -f -o short-iso -p warning`) into a
  per-VM log so failures surface as they happen; grep it against `uv run
  tools/print_signatures.py`'s output (the same strong signatures `system_debug.py` scores
  health against, not a second hand-copied list). Complements the `system_debug` snapshot
  checkpoints — a snapshot can't distinguish "still working" from a silent `until … sleep`
  wait-loop, a live tail can. See `specs/ha-dns.md`'s "Live provisioning watch" for the fuller
  write-up (stall detection, exact commands).
- **Boot-race fixes (from PR #28)** that make a TLS bring-up deterministic: `chown` otelcol's
  `file_storage` dir after the user exists; wait for the resolver to answer (`getent hosts
  registry-1.docker.io`) before docker pulls; `dpkg --force-confdef --force-confold` on repeat
  otelcol installs; add `otelcol-contrib` to the `adm` group for syslog read access.

## Verification

**Hermetic (no VMs):**
- `just check` on all clusters (`tofu fmt -check` + `validate` + `tofu test`).
- `ruff check` on `tools/` + `clusters/*/scripts/`; `bash -n` on the Justfile recipes.
- `adguard` CLI suite (`clusters/centralized_dns/tests/adguard/`), `tools/tests/test_system_debug.py`.
- Watch for the auto-tfvars gotcha: `tofu test` auto-loads `*.auto.tfvars(.json)` from the cluster
  dir, so a leftover `.cross-cluster.auto.tfvars.json`/`ca-material.auto.tfvars` flips
  `*_off_by_default` assertions. Opt-in vars are pinned OFF in each `tests/tofu/*.tftest.hcl`
  **file-level** `variables {}` block.

**Live (PKI + DNS + monitoring TLS subset):**
1. Bring up `centralized_pki` → `centralized_dns` → `centralized_monitoring` with `INTERNAL_TLS=1`,
   each wrapped in the background-journalctl + `just system-debug` feedback loop above.
2. `just set-dns centralized_monitoring` then `just verify-dns` — `grafana.<domain>` etc. resolve to
   the monitoring IP via AdGuard (no `/etc/hosts`).
3. `just tls-check-monitoring` — the Traefik leaf chains to the pinned internal root.
4. `just verify centralized_monitoring` — testinfra over SSH passes.
