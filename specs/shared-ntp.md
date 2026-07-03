# Spec: Shared Fleet Time Sync (UTC + NTP)

> **Supersedes `specs/ntp.md`.** That spec introduced UTC + `systemd-timesyncd` for the two
> original clusters; this one promotes time sync to a **fleet-wide shared service** across all
> six clusters, removes the copy-paste duplication, finishes live test coverage, and adds an
> opt-in internal NTP source. `specs/ntp.md` remains the canonical write-up of the Multipass
> host-timezone-injection quirk (reproduced below in condensed form).

## Context

"Shouldn't NTP be a default shared service for every single one of these VMs?" — yes, and in
practice it already is. Every VM in every cluster (`centralized_dns`, `centralized_logging`,
`centralized_monitoring`, `centralized_netbox`, `centralized_pki`, `centralized_unifi` — 13 VM
cloud-init templates) already boots pinned to `Etc/UTC` with `systemd-timesyncd` enabled via
cloud-init's native `ntp:` module, plus a `timedatectl set-timezone Etc/UTC` runcmd guard.

But it is **not truly *shared***. Three gaps separate "duplicated default" from "shared service":

1. **Not DRY.** The identical 4-line block is copy-pasted into 13 templates. Nothing keeps them
   in sync — a future edit to one silently diverges the fleet.
2. **Uneven test coverage.** Live `test_ntp.py` exists only for `centralized_logging`,
   `centralized_monitoring`, and `centralized_netbox`. `centralized_dns`, `centralized_pki`, and
   `centralized_unifi` carry the block (and hermetic tests) but have **no live check**.
3. **No internal NTP source.** `specs/ntp.md`'s Future Work — "point `systemd-timesyncd` at an
   internal/pool NTP server via a `write_files` drop-in for `/etc/systemd/timesyncd.conf.d/`" —
   is unbuilt. This is not just an air-gap nicety: once `dns_server` routes the fleet through the
   `centralized_dns` AdGuard hub, `systemd-timesyncd` must **resolve `ntp.ubuntu.com` at boot**
   before it can sync. An internal NTP source addressed **by IP** removes that name-resolution
   dependency entirely, making the clock resilient to a slow/unavailable resolver at first boot.

This lab exists to disagree about nothing that matters — syslog-ng writes RFC5424 timestamps,
Prometheus stamps every sample, step-ca signs `notBefore`/`notAfter`, and NetBox records change
times. A drifted or non-UTC clock desynchronizes all of it. This spec makes the baseline
explicit, single-sourced, tested everywhere, and optionally hub-pointed — so it survives image
changes and promotion to Proxmox.

## Objective

1. **Baseline (unconditional, every VM):** timezone pinned to `Etc/UTC` and an enabled,
   synchronizing `systemd-timesyncd`, sourced from **one** shared file so all 13 renders are
   byte-identical and drift-proof.
2. **Live + hermetic coverage on all six clusters.**
3. **Opt-in internal NTP source (`ntp_server`):** when set, every VM points `systemd-timesyncd`
   at an internal source by IP via a `timesyncd.conf.d/` drop-in — mirroring the `dns_server`
   pattern exactly. Default empty → turnkey `just up` is unchanged.
4. **`centralized_dns` as the natural NTP hub**, with `up-connected` auto-wiring under
   `INTERNAL_NTP=1` (paralleling `INTERNAL_TLS`).

## Decision

### Baseline — unconditional, single-sourced

The baseline is a **baseline**, not a feature: UTC + a synchronizing client is required, so it is
**not** threaded through `variables.tf` and has **no `enable_*` toggle**. (This preserves the
intent of `specs/ntp.md:71-74`; only the *hub pointer* below is opt-in.)

Its content lives in one shared snippet — `clusters/_shared/cloud-init/ntp-timesync.yaml.tftpl`
— carrying the standard `# Managed by OpenTofu — SHARED cross-cluster snippet` header and the
top-level cloud-config keys (no injected vars, so every render is identical):

```yaml
# Time sync — pin every VM to UTC and keep the clock disciplined via systemd-timesyncd.
# Declared here (not left to the image default) so timestamps align fleet-wide.
timezone: Etc/UTC
ntp:
  enabled: true
  ntp_client: systemd-timesyncd
```

Each cluster's `main.tf` renders it into a `local` and injects it at column 0 of every VM
template (before `packages:`):

```hcl
ntp_timesync = templatefile("${path.module}/../_shared/cloud-init/ntp-timesync.yaml.tftpl", {})
```

```yaml
#cloud-config
package_update: true
package_upgrade: true
${ntp_timesync}
packages:
  - ...
```

This mirrors the shared-snippet → `local` → `${...}`-injection pattern already used for
`use-dns.conf.tftpl`, `syslog-client.conf.tftpl`, etc. — the `_shared/` prefix keeps it out of
the `clusters/*/` recipe globs.

### The Multipass host-timezone gotcha (companion runcmd — stays inline)

**Multipass sets the guest timezone to the *host's* during first boot.** A VM launched on an
`America/New_York` host comes up `Timezone=America/New_York` even though user-data declares
`timezone: Etc/UTC`, because `/etc/localtime` is written once during cloud-init and Multipass
wins. The declarative key alone is therefore **not sufficient on Multipass**.

The fix is a `runcmd` — it runs in cloud-init's final stage, *after* the config modules, so it is
the last writer:

```yaml
runcmd:
  - timedatectl set-timezone Etc/UTC   # re-affirm UTC after Multipass host-TZ injection
  # ...
```

This one line **stays inline in every template**: it lives in the `runcmd:` section, a different
part of the YAML from the top-level keys, and cannot be co-injected with the baseline block. It
is a required companion of the shared block, not duplication worth factoring. On Proxmox (no
host-TZ injection) it is a harmless no-op.

### Opt-in internal NTP source — `ntp_server` (mirrors `dns_server`)

A new `var.ntp_server` (default `""`) in every cluster's `variables.tf`, in the existing
"Cross-cluster telemetry (opt-in)" block:

```hcl
variable "ntp_server" {
  description = "IP (or host[:port]) of an internal NTP source. Non-empty -> every VM points systemd-timesyncd at it via /etc/systemd/timesyncd.conf.d/. Empty (default) = image default NTP pool. See specs/shared-ntp.md."
  type        = string
  default     = ""
}
```

Wired identically to `dns_server` in each `main.tf`:

```hcl
use_ntp  = var.ntp_server != ""
ntp_conf = local.use_ntp ? templatefile("${path.module}/../_shared/cloud-init/use-ntp.conf.tftpl", {
  ntp_ip = split(":", var.ntp_server)[0]
}) : ""
```

The shared drop-in `clusters/_shared/cloud-init/use-ntp.conf.tftpl`:

```ini
# Managed by OpenTofu — SHARED cross-cluster snippet (clusters/_shared/cloud-init).
# Points systemd-timesyncd at the internal NTP source. Dropped into
# /etc/systemd/timesyncd.conf.d/; systemd-timesyncd merges *.conf drop-ins.
[Time]
NTP=${ntp_ip}
```

Gated `write_files` + `runcmd` blocks in each VM template, next to the `dns_server` blocks:

```yaml
%{ if ntp_server != "" ~}
  - path: /etc/systemd/timesyncd.conf.d/99-centralized-ntp.conf
    permissions: '0644'
    content: |
      ${indent(6, ntp_conf)}
%{ endif ~}
```

```yaml
%{ if ntp_server != "" ~}
  - systemctl restart systemd-timesyncd
%{ endif ~}
```

No resolver-readiness gate is needed (unlike `dns_server`): NTP-by-IP does not resolve a
hostname, so it cannot lose the boot-time DNS warm-up race. A `count = local.use_ntp ? 1 : 0`
hot-push `local_file` pair (parallel to the DNS `*_resolved_conf` resources) lets
`refresh-cross-cluster` scp the drop-in onto running VMs without a recreate.

### `centralized_dns` as the NTP hub

`centralized_dns` already "comes up FIRST" in `up-connected` and is the fleet's resolver hub;
it is the natural NTP hub too. Because `systemd-timesyncd` is client-only and **cannot serve**
time, the hub runs `chrony` host-level (matching its host-level AdGuard/Unbound style),
configured to `allow` the lab subnet with `local stratum 10` so it serves even if upstream is
briefly unreachable, while keeping an upstream `pool` for its own discipline. `up-connected`
injects `ntp_server = <dns_ipv4>` fleet-wide under `INTERNAL_NTP=1`, the same mechanism as
`INTERNAL_TLS` / `dns_server`.

### Files carrying the baseline injection

| Cluster | Templates | Rendered `local_file` |
|---|---|---|
| centralized_logging | `central`, `k0s-client`, `docker-client` | `central_ci`, `k0s_ci`, `docker_ci` |
| centralized_monitoring | `server`, `k0s-client` | `server_ci`, `k0s_ci` |
| centralized_dns | `server` | `server_ci` |
| centralized_netbox | `server`, `client`, `agent` | `server_ci`, `client_ci`, `agent_ci` |
| centralized_pki | `ca`, `services` | `ca_ci`, `services_ci` |
| centralized_unifi | `usg`, `controller` | `usg_ci`, `controller_ci` |

## Rollout (three independently-shippable phases)

- **Phase 1 — Foundation (no behavior change).** Factor the baseline into
  `ntp-timesync.yaml.tftpl`, wire through every `main.tf`/template, add the 3 missing live
  `test_ntp.py`, extend hermetic tests to assert renders match the shared source. Runtime
  behavior is byte-for-byte identical to today.
- **Phase 2 — Opt-in `ntp_server`.** Add the var + `use-ntp.conf.tftpl` + gated blocks +
  hot-push across all six clusters. Default empty → `just up` unchanged.
- **Phase 3 — Hub + auto-wiring.** `chrony` on `centralized_dns`; `INTERNAL_NTP=1 just
  up-connected` wires `ntp_server=<dns_ip>` fleet-wide; `refresh-cross-cluster` hot-push;
  `verify-connected` NTP assertion.

## Test Coverage

Two layers, mirroring the repo convention (`just check` hermetic, `just verify` live).

### Hermetic (no VMs) — `tests/tofu/sizing_and_render.tftest.hcl`

- **Baseline:** a `run "ntp_timezone_render" { command = plan }` asserts every `*_ci.content`
  contains `timezone: Etc/UTC` and `ntp_client: systemd-timesyncd` (via the
  `alltrue([for c in [...] : strcontains(c, ...)])` idiom; plain `strcontains` for single-VM
  `centralized_dns`), plus a `can(yamldecode(...))` guard that the injected block keeps the
  document valid YAML. This run now doubles as the drift guard: a template that drops the
  `${ntp_timesync}` injection fails it.
- **Opt-in:** `run "ntp_server_off_by_default"` asserts `!strcontains(..., "99-centralized-ntp.conf")`
  across every `*_ci`; `run "ntp_server_on_renders_dropin"` sets a run-scoped
  `variables { ntp_server = "10.0.0.9" }` and asserts the drop-in path + `NTP=10.0.0.9` render.
  `ntp_server` is pinned OFF in each file's file-level `variables {}` block so an auto-loaded
  `.cross-cluster.auto.tfvars.json` cannot flip the off-by-default run (see the CLAUDE.md gotcha).

### Live (over SSH) — `tests/testinfra/test_ntp.py`

Present in **all six clusters** (previously three). Parametrized over every role via
`@pytest.mark.parametrize("role", ROLES)` + `request.getfixturevalue(role)`. Each VM is checked
with `timedatectl`:

- `Timezone == Etc/UTC`
- `NTP == yes` and `systemctl is-active systemd-timesyncd == active`
- `NTPSynchronized == yes` (polled up to 120s to tolerate first-boot sync lag)

No skip guard — the baseline is unconditional. For the hub, an additional check asserts `chrony`
serves `udp/123`; for a consumer brought up with `ntp_server` set,
`/etc/systemd/timesyncd.conf.d/99-centralized-ntp.conf` exists and `timedatectl` reflects the
internal source.

## Validation

```sh
# Hermetic across the whole fleet (incl. new ntp_server_* runs):
just check centralized_dns && just check centralized_logging && just check centralized_monitoring \
  && just check centralized_netbox && just check centralized_pki && just check centralized_unifi

# Drift guard — must return ZERO hard-coded hits after the DRY refactor
# (only the shared snippet + rendered .rendered/ output carry the literal):
git grep -n "timezone: Etc/UTC" clusters/*/cloud-init

# Live on a previously-uncovered cluster (cloud-init changes require recreate, not up):
just recreate centralized_dns
cd clusters/centralized_dns/tests/testinfra && uv run pytest -v -k ntp

# Phase 3 e2e — fleet up with the internal NTP hub wired:
INTERNAL_NTP=1 just up-connected && just verify-connected
```

> **Note:** editing cloud-init does **not** re-provision an existing VM — OpenTofu won't recreate
> a `multipass_instance` when only the rendered `local_file` content changes. Use `just recreate
> <cluster>` to redeploy cloud-init changes to already-running VMs.

## Future Work

- Swap `systemd-timesyncd` for `chrony` on a promoted Proxmox target that must **serve** time to
  peers (the hub already demonstrates the chrony config).
- Have the hub's `chrony` discipline against the Proxmox/homelab host or a GPS/PPS source when
  the lab is run air-gapped.
