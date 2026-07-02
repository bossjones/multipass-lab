# Spec: Cluster Time Sync (UTC + NTP)

## Context

Both lab clusters — `clusters/centralized_logging/` and `clusters/centralized_monitoring/` —
exist to demonstrate cross-VM log shipping and metric scraping. Both are worthless if the VMs
disagree about the time: syslog-ng writes RFC5424 timestamps and Prometheus stamps every sample,
so a VM whose clock has drifted (or whose timezone is not UTC) produces logs and metrics that no
longer line up with the rest of the cluster.

Until now neither cluster declared a timezone or NTP client in cloud-init; both silently relied
on the Ubuntu 24.04 cloud-image default (`Etc/UTC` + `systemd-timesyncd`). This spec makes that
guarantee **explicit and tested**, so it survives image changes and stays true when the same
OpenTofu modules are later promoted to a Proxmox target.

## Objective

Every VM in both clusters boots with:

1. **Timezone pinned to `Etc/UTC`.**
2. **An enabled, synchronizing NTP client** (`systemd-timesyncd`).

...and both properties are verified at two layers of test (hermetic render + live behavior).

## Decision

Use cloud-init's **native modules** rather than hand-rolled `runcmd`. The following identical,
**unconditional** block is added near the top of every VM's `*.yaml.tftpl` (after
`package_upgrade: true`, before `packages:`):

```yaml
# Time sync — pin every VM to UTC and keep the clock disciplined via systemd-timesyncd.
# Declared here (not left to the image default) so log/metric timestamps align cluster-wide.
timezone: Etc/UTC
ntp:
  enabled: true
  ntp_client: systemd-timesyncd
```

...plus a `runcmd` enforcement as the first runcmd entry in every VM template:

```yaml
runcmd:
  - timedatectl set-timezone Etc/UTC
  # ... existing runcmd steps ...
```

### Multipass gotcha: host-timezone injection

**Multipass sets the guest timezone to the host's timezone during first boot.** Verified live:
a VM launched on an `America/New_York` host came up with `Timezone=America/New_York` even though
our user-data declared `timezone: Etc/UTC`. `/etc/localtime` is written once during cloud-init
(mtime never changes afterward), so Multipass wins the timezone the declarative `timezone:` key
sets. The declarative key alone is therefore **not sufficient on Multipass**.

The `runcmd` runs in cloud-init's final stage — *after* the config modules that set the
timezone — so `timedatectl set-timezone Etc/UTC` is the last writer and wins. On Proxmox (no
host-TZ injection) the runcmd is a harmless no-op that just re-affirms UTC. Keeping the
declarative `timezone:` key too documents intent and covers platforms without this quirk.

> **Note:** changing only the rendered cloud-init does **not** re-provision an existing VM —
> OpenTofu won't recreate a `multipass_instance` when just the `local_file` content changes. Use
> `just recreate <cluster>` (destroy + up) to redeploy cloud-init changes to already-running VMs.

Rationale:

- **`systemd-timesyncd`, not chrony.** timesyncd ships on the Ubuntu 24.04 cloud image, so no
  package is added — the `ntp:` module only enables the service and writes its drop-in config.
  This is the lightest touch and matches the cheap-lab ethos. A Proxmox promotion that needs a
  full NTP daemon is a one-line `ntp_client:` change plus a service-name tweak in the live test.
- **Unconditional, no `enable_*` toggle.** UTC + time sync is a baseline requirement, not an
  optional feature, so it is *not* threaded through `variables.tf` / `local.flags`. These are
  static top-level cloud-config keys; the existing `templatefile(...)` → `local_file` →
  `.rendered/` pipeline renders them as-is with no `main.tf` changes.
- **`Etc/UTC`, not `UTC`.** Matches the Ubuntu cloud-image default; `timedatectl` reports
  `Timezone=Etc/UTC`, which the live test asserts exactly.

### Files carrying the block

| Cluster | Template | Rendered `local_file` |
|---|---|---|
| centralized_logging | `cloud-init/central.yaml.tftpl` | `local_file.central_ci` |
| centralized_logging | `cloud-init/k0s-client.yaml.tftpl` | `local_file.k0s_ci` |
| centralized_logging | `cloud-init/docker-client.yaml.tftpl` | `local_file.docker_ci` |
| centralized_monitoring | `cloud-init/server.yaml.tftpl` | `local_file.server_ci` |
| centralized_monitoring | `cloud-init/k0s-client.yaml.tftpl` | `local_file.k0s_ci` |

## Test Coverage

Two layers, mirroring the repo convention (`just check` hermetic, `just verify` live).

### Hermetic (no VMs) — `tests/tofu/sizing_and_render.tftest.hcl`

A `run "ntp_timezone_render" { command = plan }` block in each cluster asserts, across every
`*_ci` resource, that the rendered cloud-init contains `timezone: Etc/UTC` and
`ntp_client: systemd-timesyncd`, plus a `can(yamldecode(...))` guard proving the injected keys
keep the document valid YAML. Uses the existing `alltrue([for ... : strcontains(...)])` idiom.

### Live (over SSH) — `tests/testinfra/test_ntp.py`

Parametrized over every role fixture (logging: `central`, `k0s`, `docker`; monitoring: `server`,
`k0s`) via `request.getfixturevalue(role)`. Each VM is checked with `timedatectl`:

- `Timezone == Etc/UTC`
- `NTP == yes` and `systemctl is-active systemd-timesyncd == active`
- `NTPSynchronized == yes` (polled up to 120s to tolerate first-boot sync lag)

No skip guard is needed because the config is unconditional. `conftest._connect` already blocks
on `cloud-init status --wait`, so the config is applied before assertions run.

## Validation

```sh
just check centralized_logging      # hermetic: fmt + validate + tftest (incl. ntp_timezone_render)
just check centralized_monitoring
just up centralized_logging && just verify centralized_logging   # live: launch + testinfra
just up centralized_monitoring && just verify centralized_monitoring
# or, against already-running VMs:
cd clusters/centralized_logging/tests/testinfra && uv run pytest -v -k ntp
```

## Future Work

- Point `systemd-timesyncd` at an internal/pool NTP server (e.g. a homelab or Proxmox host) via
  a `write_files` drop-in for `/etc/systemd/timesyncd.conf.d/` if the lab is ever run air-gapped.
- Swap to chrony if a promoted Proxmox target needs a full NTP daemon (serve time to peers).
