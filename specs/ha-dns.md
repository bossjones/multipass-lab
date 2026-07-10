# Plan: High-Availability mode for `centralized_dns` (keepalived VIP + AdGuardHome-Sync)

Status: **implemented (code + hermetic tests); live VIP feasibility spike + live bring-up still
TODO** · Task type: **feature** · Complexity: **complex**
Extends: `specs/centralized_dns.md` (single-VM AdGuard Home + Unbound cluster)
Repo precedent to mirror: `centralized_k0s` opt-in etcd-quorum HA behind an HAProxy edge (`specs/centralized_k0s.md`)

**Implementation note (read before touching `main.tf`):** two parts of this plan's original
"Solution Approach" (items 2–3, 5–6) turned out to be unsound against how OpenTofu actually
resolves state addresses and dependency cycles, and were corrected during implementation:

1. **`multipass_instance.server` was NOT converted to a unified `for_each` keyed by role.**
   Doing so changes its state address even when `enable_ha` stays `false` (OpenTofu tracks
   resources by address, not by the `name` attribute), which would destroy/recreate every
   existing deployment's DNS VM. Instead `multipass_instance.server` (+ `local_file.server_ci`)
   stays its own resource, gated `count = local.ha ? 0 : 1`, migrated in place with `moved`
   blocks; HA nodes are a wholly separate `multipass_instance.node` (`for_each`) resource —
   mirrors `centralized_k0s`'s dedicated `haproxy` resource, not a single unified fan-out.
2. **Neither the keepalived `unicast_peer` NOR the AdGuardHome-Sync `secondary_ip` reference is
   baked into `node_ci`'s first-boot cloud-init render.** A `for_each` resource
   (`local_file.node_ci`) referencing another `for_each` resource (`multipass_instance.node`) by
   a sibling key is treated as a **whole-resource cycle** by OpenTofu's graph analysis
   (confirmed via `tofu validate`) — even where only one direction is actually referenced per
   instance (e.g. AdGuardHome-Sync's primary→secondary reference). Both are deferred to
   standalone post-apply resources (`local_file.keepalived_peer_conf` /
   `terraform_data.keepalived_peer_push`, and `local_file.adguardhome_sync_conf` /
   `terraform_data.adguardhome_sync_push`), rendered and pushed over SSH only after both nodes
   exist — mirroring `centralized_k0s`'s `terraform_data.k0s_bootstrap` post-apply idiom. First
   boot installs keepalived + the health script (peer-less) and the AdGuardHome-Sync binary +
   unit (config-less) but does not start either; the post-apply push writes the real config and
   starts each service for the first time.

The rest of the plan below (variables, keepalived config shape, health probe, AdGuardHome-Sync
config, Justfile rewiring, CLI changes, test structure, docs) stands as designed. Everything
except the Task 1 live feasibility spike and Task 12's live bring-up/failover test has been
implemented; those two remain for a live Multipass run.

## Task Description

Add an **opt-in high-availability mode** to the existing `clusters/centralized_dns/`
cluster. Today that cluster is a single VM running AdGuard Home (`:53`) over a local
Unbound (`127.0.0.1:5335`), host-level under systemd. This plan makes DNS survive the
loss of one node by adding, **behind a single `enable_ha` flag (default off)**:

- **Two self-contained AdGuard nodes** (`primary` + `secondary`), each running its own
  AdGuard Home **and** its own local Unbound + exporters — no shared upstream, so a node
  is independently complete.
- **keepalived** (VRRP, **unicast** peering) presenting one **floating Virtual IP (VIP)**
  that the whole fleet resolves against. The VIP floats to a healthy node on failure.
- A **`vrrp_script` health check that verifies AdGuard actually *answers DNS*** (not just
  that the process is alive), so the VIP leaves a node whose resolver is hung.
- **AdGuardHome-Sync** (`bakito/adguardhome-sync`, host-level systemd unit) replicating
  config **unidirectionally from `primary` (origin) → `secondary` (replica)**: blocklists,
  rewrites, filtering rules, and settings stay identical without a shared-storage SPOF.

Everything runs **host-level under systemd — no Docker** — consistent with the existing
cluster's explicit design. When `enable_ha = false` (the default), the cluster renders
**byte-for-byte what it does today**: one `server` VM, no keepalived, no sync. HA is
purely additive.

## Objective

`just up centralized_dns` with `enable_ha = false` is unchanged (single `server` VM).
`enable_ha = true` brings up two AdGuard+Unbound nodes fronted by a keepalived VIP, with
`primary`→`secondary` config replication, such that:

- The whole fleet resolves DNS through the **VIP** (`dns_server` = VIP in HA mode).
- Killing `AdGuardHome` (or the whole VM) on the node holding the VIP moves the VIP to the
  healthy node in **< 5s**, and clients keep resolving with no reconfiguration.
- Config changes made on `primary`'s UI appear on `secondary` within one sync interval.
- `just verify centralized_dns` (HA-aware), `just verify-api centralized_dns`, and
  `just verify-connected` all pass in both modes.

## Problem Statement

`centralized_dns` is a **single VM** and the entire fleet points `systemd-resolved` at its
one IP (`specs/cross-cluster.md`: DNS is the hub that comes up FIRST; every VM wires its
resolver to it at first boot). That makes the DNS VM a **hard single point of failure**:
if it reboots, wedges, or is recreated, every other VM loses name resolution — and because
the fleet points at a *specific VM IP*, even a planned rebuild churns the address the whole
fleet depends on.

We want DNS to tolerate the loss of one node **without changing the address the fleet
points at**. Two independent problems must both be solved:

1. **Failover of the endpoint** — clients must not need to know *which* node is healthy.
   Passive "two DNS servers in DHCP" (one of the source blogs) is rejected: resolvers cache
   a dead primary for ~30s and there's no single stable endpoint. A floating **VIP** gives
   one address with sub-second failover.
2. **Config consistency** — two AdGuard instances drift immediately (blocklists, rewrites,
   per-client rules) unless replicated. NFS-shared-config (another source blog) is rejected:
   it adds a storage SPOF and risks corruption on concurrent writes. **AdGuardHome-Sync**
   replicates over the AdGuard API with no shared storage.

### Why this shape (best-practice distillation from the four source posts)

| Source | Failover | Config sync | Kept? |
|---|---|---|---|
| realmenweardress.es | keepalived VRRP + VIP | none | **VIP: yes.** But it health-checks only keepalived liveness, **not** whether AdGuard answers — we fix that with a real DNS `vrrp_script`. |
| archy.net (Docker Swarm) | manual / round-robin | **NFS shared config** | **Rejected** — NFS SPOF, concurrent-write corruption, no auto-failover, Swarm+compose hybrid. |
| prajwolbikramadhikari | DHCP two-DNS-servers (passive) | none | **Rejected** — ~30s client-cache failover, drift across hand-configured instances. |
| pablomurga.com | keepalived + VIP + `vrrp_script` (2s) | **AdGuardHome-Sync** (bakito) | **Adopted as the model** — active health-checked failover + real replication. |

Sources: [realmenweardress.es](https://realmenweardress.es/2024/05/dockerised-vip-accessible-dns/),
[archy.net](https://www.archy.net/setting-up-an-adguard-home-cluster-with-shared-configuration-on-docker-swarm/),
[prajwolbikramadhikari](https://prajwolbikramadhikari.com.np/projects/homelab-series-part-3-high-availability-dns/),
[pablomurga.com](https://pablomurga.com/posts/adguard-home/).

### Open risk we are deliberately de-risking first (the VIP on Multipass)

VRRP presents a floating VIP as an **extra IP on a node's NIC**, advertised via VRRP and
resolved on the L2 segment via **gratuitous ARP**. On a real homelab L2 network this is
routine. On **Multipass on macOS** the VMs sit on a NAT'd/bridged network (`mpqemubr0` /
the QEMU vmnet bridge), and it is **not guaranteed** that (a) VRRP advertisements reach the
peer, (b) gratuitous ARP for a phantom VIP is honored by the bridge, or (c) the **Mac host**
can even route to the VIP. We therefore:

- Default to **unicast VRRP** (`unicast_src_ip` + `unicast_peer`), which sidesteps multicast
  on the bridge (advertisements go point-to-point node→node). Parameterized so a Proxmox
  target can flip to multicast later.
- **Front-load a feasibility spike (Task 1)** that proves VIP reachability + failover on
  Multipass *before* any cluster/CLI/test investment. If the VIP is unreachable from the Mac
  host, we surface it immediately and fall back (documented) rather than discovering it after
  building everything.

## Solution Approach

1. **`enable_ha` flag on `centralized_dns`** (bool, default `false`), mirroring
   `centralized_k0s`'s `k0s_control_plane_count > 1` → `ha_mode` pattern. Off = today's
   single `server` VM, zero behavior change. On = two nodes + VIP + sync layer.

2. **Two count/role-driven VMs in HA mode** — `primary` and `secondary`. The existing
   single-VM cloud-init (`cloud-init/server.yaml.tftpl`) becomes a **role-parameterized
   base** reused by both nodes (AdGuard + Unbound + exporters render identically per node;
   only role-tagged hostname/telemetry labels differ — the k0s `role`/`role_index` idiom).

3. **keepalived on each node** (apt `keepalived`, systemd unit), unicast VRRP, one VIP:
   - `primary`: `state MASTER`, `priority 200`; `secondary`: `state BACKUP`, `priority 100`.
   - Shared `virtual_router_id`, unicast auth password, `advert_int 1`.
   - `vrrp_script chk_adguard` runs every 2s: **`dig +short +time=1 +tries=1 @127.0.0.1
     health.check.local` (or a `getent`/port probe) and requires AdGuard to actually
     answer**; failure subtracts enough weight to drop below the peer so the VIP moves.
   - AdGuard binds `0.0.0.0:53` on each node (so it answers on the VIP the instant VRRP
     assigns it — see AdGuard issue #6506: binding specific IPs breaks VIP answering).

4. **AdGuardHome-Sync** as a **single systemd unit on `primary`** (origin), pushing to
   `secondary` (replica) on a timer:
   - Origin = `primary`'s AdGuard API (`http://127.0.0.1:3000`); replica =
     `secondary`'s API (`http://<secondary_ip>:3000`).
   - Unidirectional: **all config edits happen on `primary`'s UI**; `secondary` is
     overwritten each sync (documented gotcha — never edit `secondary` directly).
   - Installed from the `bakito/adguardhome-sync` **release binary** (not the Docker image),
     wrapped in a systemd unit + `EnvironmentFile` (same idiom as the exporters).

5. **Fleet wiring points at the VIP in HA mode.** The `dns_server` value the rest of the
   fleet consumes becomes the **VIP** (not a node IP) when `enable_ha = true`. A new output
   `dns_endpoint` = VIP (HA) / `server` IP (single) is the single source the Justfile reads,
   so `up-connected`, the health-gate, and `set-dns-all` need no mode-specific branching.

6. **DNS rewrites push to the ORIGIN, not the VIP.** `just set-dns-all` / Traefik hostname
   records target `primary`'s real IP (`origin`), and **AdGuardHome-Sync propagates them to
   `secondary`**. Pushing at the VIP would race the sync (a rewrite written to `secondary`
   is clobbered on the next sync cycle). A new output `dns_rewrite_target` = `primary` IP
   (HA) / `server` IP (single) is what the rewrite recipes read.

7. **Telemetry per node.** Each node keeps its own exporters + syslog/otel agents (the
   existing gated blocks), so Prometheus scrapes both nodes and both ship logs. The
   `up-connected` scrape-target hot-push enumerates both nodes' `:9100/:9618/:9167` in HA
   mode.

8. **Two-layer tests, HA-parameterized** — hermetic `tofu test` asserts the keepalived +
   sync render iff `enable_ha`, and that single-mode still renders exactly one `server`;
   live testinfra adds a **failover test** (kill AdGuard on the VIP holder, assert the VIP
   moves and the VIP still resolves).

### What single-mode (`enable_ha = false`) must still produce (regression guard)

One `server` VM, role `server`, no keepalived/sync packages or units, `dns_endpoint` =
`dns_rewrite_target` = `server` IP. Every one of the ~5 clusters already wired to
`dns_server` and the existing `centralized_dns` tests must pass **unchanged**. HA code lives
behind `count`/`for_each` on `enable_ha` and `%{ if enable_ha }` cloud-init gates.

## Relevant Files

### Existing files to read / imitate

- `specs/centralized_dns.md` — the parent spec; the single-VM stack, `:53` contention
  ordering, exporter set, and cross-cluster wiring this plan extends. **Read first.**
- `clusters/centralized_dns/main.tf`, `variables.tf`, `outputs.tf`,
  `cloud-init/server.yaml.tftpl`, `cloud-init/adguard/AdGuardHome.yaml.tftpl`,
  `cloud-init/unbound/unbound.conf` — the module being extended. `server.yaml.tftpl` is
  refactored into the role-parameterized base.
- `clusters/centralized_k0s/main.tf` — **the HA pattern to mirror**: `ha_mode =
  var.k0s_control_plane_count > 1`, `count`-driven node instances with `role`/`role_index`,
  the conditional edge (`haproxy[0]`) created only in HA mode, and `k0s_api_ipv4` resolving
  to the edge IP in HA / the single node in non-HA. `dns_endpoint`/`dns_rewrite_target`
  mirror `k0s_api_ipv4` exactly.
- `clusters/centralized_k0s/cloud-init/haproxy.yaml.tftpl` (+ `controller.yaml.tftpl`) —
  the conditional-edge cloud-init + role-tagged base-template idiom keepalived reuses.
- `clusters/centralized_dns/scripts/{_dns_common.py,adguard_cli.py,unbound_cli.py}` — the
  host CLIs; `adguard_cli.py` gains HA-aware commands (`sync-status`, node fan-out).
- `clusters/centralized_dns/tests/{tofu,testinfra,adguard,unbound,dns_common}/` — both test
  layers to extend (HA render assertions + live failover test).
- `Justfile` — `up`, `up-connected` (DNS-first ordering + health-gate), `set-dns-all`,
  `verify`, `verify-connected`, `open`. The health-gate/rewrite recipes switch to reading
  `dns_endpoint`/`dns_rewrite_target`.
- `specs/cross-cluster.md` — the `dns_server` signal + DNS-first ordering to amend (fleet
  now points at the VIP in HA mode).

### New Files

- `clusters/centralized_dns/cloud-init/keepalived/keepalived.conf.tftpl` — rendered per node
  (`state`, `priority`, `unicast_src_ip`, `unicast_peer`, `virtual_ipaddress`, `vrrp_script`).
- `clusters/centralized_dns/cloud-init/keepalived/chk_adguard.sh.tftpl` — the health-probe
  script the `vrrp_script` invokes (dig `@127.0.0.1`, exit nonzero if no answer).
- `clusters/centralized_dns/cloud-init/adguardhome-sync/adguardhome-sync.yaml.tftpl` — the
  sync config (origin `primary`, replica `secondary`, interval, API creds) — **rendered on
  `primary` only**.
- `clusters/centralized_dns/cloud-init/adguardhome-sync/adguardhome-sync.service` — systemd
  unit (installed on `primary` only).
- `specs/ha-dns.md` — this document.

### Files that change shape

- `cloud-init/server.yaml.tftpl` → parameterized base rendered for `server` (single) or
  `primary`/`secondary` (HA); add gated keepalived + (primary-only) sync install blocks.
- `variables.tf` — add `enable_ha`, `vip_address`, `vrrp_router_id`, `vrrp_auth_pass`,
  `vrrp_use_unicast` (default `true`), `adguardhome_sync_version`, `sync_interval`.
- `outputs.tf` — add `dns_endpoint`, `dns_rewrite_target`, `vip_address`; `hosts` gains
  `primary`/`secondary` in HA mode.

## Implementation Phases

### Phase 1: De-risk (feasibility spike)

Prove the VIP works on Multipass before building anything reusable. Throwaway, but its
findings pin the VRRP transport and VIP defaults for the real work.

### Phase 2: HA foundation (OpenTofu + cloud-init)

`enable_ha` flag, count/role-driven nodes, the role-parameterized base cloud-init,
keepalived render + health script, and the `primary`-only AdGuardHome-Sync unit. Wire the
new `dns_endpoint`/`dns_rewrite_target` outputs.

### Phase 3: Orchestration, CLIs, tests, docs

Point `up-connected`/health-gate/`set-dns-all` at the new outputs, add HA-aware CLI
commands, extend both test layers (incl. the live failover test), and document.

## Step by Step Tasks

IMPORTANT: Execute every step in order, top to bottom.

### 1. Feasibility spike — prove the VIP on Multipass (throwaway)

- Manually (or via a scratch `.auto.tfvars`) launch two Ubuntu Multipass VMs on the same
  subnet as today's DNS VM.
- **Start a live background tail on both scratch VMs BEFORE installing keepalived** — first
  boot is the rockiest part of this whole plan, so watch it from the start, not after something
  breaks. These are throwaway VMs with no tofu `hosts` output and no `centralized_dns` Justfile
  recipe yet, so reach them by raw `ssh` (same flags `tools/_system_debug_core.SSH_OPTS` uses),
  not `just tail-log`:
  ```bash
  ip_a=$(multipass info dns-spike-a --format json | jq -r '.info["dns-spike-a"].ipv4[0]')
  ip_b=$(multipass info dns-spike-b --format json | jq -r '.info["dns-spike-b"].ipv4[0]')
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      -o ConnectTimeout=8 -o BatchMode=yes -i ~/.ssh/id_ed25519 ubuntu@"$ip_a" \
      'sudo journalctl -f -o short-iso -p warning' > scratchpad/dns-spike-a.log 2>&1
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      -o ConnectTimeout=8 -o BatchMode=yes -i ~/.ssh/id_ed25519 ubuntu@"$ip_b" \
      'sudo journalctl -f -o short-iso -p warning' > scratchpad/dns-spike-b.log 2>&1
  ```
  (Bash tool, `run_in_background: true` for each.)
- On each, `apt install -y keepalived`, drop a **unicast** `keepalived.conf` (MASTER/BACKUP,
  shared `virtual_router_id`, `unicast_src_ip`/`unicast_peer` = the two node IPs,
  `virtual_ipaddress <candidate VIP in the Multipass subnet>`), `systemctl enable --now
  keepalived`.
- Periodically grep both tails against the centralized signature list (never hand-copy it):
  `grep -iE "$(uv run tools/print_signatures.py)" scratchpad/dns-spike-*.log`. Any hit is a
  stop-and-look signal — don't wait for the "Verify" steps below to notice it first.
- **Stall check** (a silent `until … sleep` gate looks identical to healthy-but-slow to a
  point-in-time check — see "Live provisioning watch" in Testing Strategy): if a tail goes
  quiet for **> 90s** (`age=$(( $(date +%s) - $(date -r scratchpad/dns-spike-a.log +%s) ))`)
  while `cloud-init status --long` still shows work outstanding (or, once keepalived is dropped
  in, `systemctl status keepalived` isn't yet active), ssh in and check
  `ps -o pid,ppid,args -ax | grep -E 'runcmd|sleep'` rather than continuing to wait.
- **Verify, in order:**
  1. `ip addr` on MASTER shows the VIP; on BACKUP it does not.
  2. **From the Mac host**, `dig @<VIP> example.com` succeeds (install a throwaway resolver
     on the VIP or just `nc`/ping first — the key question is *host→VIP reachability*).
  3. `systemctl stop keepalived` on MASTER → VIP appears on BACKUP within a few seconds and
     `dig @<VIP>` still answers.
- **Decision gate:** if the Mac host cannot reach the VIP even with unicast VRRP, STOP and
  record the fallback in this spec (candidates: run the failover probe **VM-to-VM only** and
  have the fleet point at the VIP — fleet VMs share the bridge and may reach it even if the
  Mac host can't; or, last resort, document HA as Proxmox-target-only and keep Multipass
  single-VM). Do not proceed to Phase 2 on an unproven VIP.
- Tear the scratch VMs down (`just prune` / `multipass delete`). Record the working VIP
  address, transport, and any subnet constraints in `clusters/centralized_dns/README.md`.

### 2. Add HA variables

In `clusters/centralized_dns/variables.tf`:

```hcl
variable "enable_ha" {
  description = "Opt-in HA: false (default) = single `server` VM (unchanged); true = 2 nodes (primary+secondary) behind a keepalived VIP with AdGuardHome-Sync replication."
  type        = bool
  default     = false
}
variable "vip_address" {
  description = "Floating Virtual IP the fleet resolves against in HA mode. Must be a free address on the Multipass subnet (see the Task 1 spike). Ignored when enable_ha = false."
  type        = string
  default     = ""
}
variable "vrrp_router_id"   { type = number, default = 51 }
variable "vrrp_auth_pass"   { type = string, default = "changeme-vrrp-lab", sensitive = true }
variable "vrrp_use_unicast" { type = bool,   default = true }   # unicast on Multipass; multicast on real L2
variable "adguardhome_sync_version" { type = string, default = "<pin at impl>" }
variable "sync_interval"    { type = string, default = "5m" }
```

- Add a validation: `enable_ha => vip_address != ""` (a `precondition` or `validation` block)
  so HA can't come up without a VIP.

### 3. Count/role-driven nodes in `main.tf`

Mirror `centralized_k0s`:

```hcl
locals {
  ha        = var.enable_ha
  node_defs = local.ha ? { primary = 200, secondary = 100 } : { server = 0 }
  # dns_endpoint: what the FLEET resolves against.
  dns_endpoint       = local.ha ? var.vip_address : multipass_instance.node["server"].ipv4
  # dns_rewrite_target: where set-dns-all pushes rewrites (origin in HA, so sync replicates).
  dns_rewrite_target = local.ha ? multipass_instance.node["primary"].ipv4 : multipass_instance.node["server"].ipv4
}
```

- Convert the single `multipass_instance.server` to `for_each = local.node_defs` (key =
  role). Single mode yields exactly one instance keyed `server` → **identical VM name
  `${name_prefix}-server`, so single-mode state/outputs are unchanged**. HA yields
  `${name_prefix}-primary` and `-secondary`.
- Render `local_file.node_ci` per role via the parameterized base template, passing
  `role`, `priority`, `peer_ip` (the other node's IP — the k0s cross-reference idiom;
  `primary` references `secondary.ipv4` and vice-versa — watch for the dependency edge,
  same as k0s controllers), `is_origin = role == "primary"`, `vip`, VRRP vars.
- **Sizing:** each HA node keeps the existing single-VM size (DNS + Unbound + exporters are
  light); keepalived + sync add negligible load. No auto-bump needed.

### 4. Refactor `server.yaml.tftpl` into a role-parameterized base

- Keep the entire existing single-VM body (Unbound, `:53` contention ordering, AdGuard seed,
  exporters, telemetry) — it already renders per node unchanged.
- Add gated blocks, all `%{ if enable_ha ~}`:
  - `packages:` += `keepalived`.
  - `write_files:` += `/etc/keepalived/keepalived.conf` (from the rendered template) and
    `/usr/local/sbin/chk_adguard.sh` (`0755`).
  - `runcmd:` += (after AdGuard is answering on `:53`) `unbound-checkconf`-style gate then
    `systemctl enable --now keepalived`.
  - **`primary`-only** (`%{ if enable_ha && is_origin ~}`): install the AdGuardHome-Sync
    binary (arch-aware release download, pinned version), write
    `/etc/adguardhome-sync/adguardhome-sync.yaml` + the systemd unit + `EnvironmentFile`,
    `systemctl enable --now adguardhome-sync`.
- AdGuard seed (`AdGuardHome.yaml.tftpl`): confirm `dns.bind_hosts: [0.0.0.0]` (answers on
  the VIP). The seed is identical on both nodes at first boot; sync keeps them identical after.

### 5. Render keepalived config + health script

- `keepalived.conf.tftpl`:
  ```
  vrrp_script chk_adguard {
      script "/usr/local/sbin/chk_adguard.sh"
      interval 2
      weight -60          # drop below the 100-point priority gap on failure
      fall 2
      rise 2
  }
  vrrp_instance VI_DNS {
      state ${state}                       # MASTER on primary, BACKUP on secondary
      interface ${vrrp_iface}              # discover at impl (likely ens3/enp0s2)
      virtual_router_id ${vrrp_router_id}
      priority ${priority}                 # 200 / 100
      advert_int 1
      %{ if vrrp_use_unicast ~}
      unicast_src_ip ${this_ip}
      unicast_peer { ${peer_ip} }
      %{ endif ~}
      authentication { auth_type PASS  auth_pass ${vrrp_auth_pass} }
      virtual_ipaddress { ${vip} }
      track_script { chk_adguard }
  }
  ```
- `chk_adguard.sh.tftpl`: `dig +short +time=1 +tries=1 @127.0.0.1 example.com >/dev/null` (or
  a query for a known-good local name); `exit 1` on failure. Runs as a real DNS answer probe,
  not a process check.

### 6. AdGuardHome-Sync config + unit (`primary` only)

- `adguardhome-sync.yaml.tftpl`:
  ```yaml
  origin:  { url: "http://127.0.0.1:${adguard_web_port}", username: "${adguard_user}", password: "${adguard_password}" }
  replicas:
    - { url: "http://${secondary_ip}:${adguard_web_port}", username: "${adguard_user}", password: "${adguard_password}" }
  cron: "@every ${sync_interval}"
  runOnStart: true
  features: { generalSettings: true, filters: true, dhcp: false, clients: true, dns: { rewrites: true } }
  ```
  (`dhcp: false` — AdGuard isn't the DHCP server here.)
- `adguardhome-sync.service`: `ExecStart=/usr/local/bin/adguardhome-sync run --config
  /etc/adguardhome-sync/adguardhome-sync.yaml`, `Restart=always`, `After=network-online.target`.
- Creds come from the existing `adguard_user`/`adguard_password` (plaintext for the API, as
  the exporter already uses).

### 7. New outputs + Justfile rewiring

- `outputs.tf`: add `dns_endpoint`, `dns_rewrite_target`, `vip_address` (HA only, else `""`);
  `hosts` becomes `{ primary = {...}, secondary = {...} }` in HA / `{ server = {...} }` single.
- `Justfile`:
  - `up-connected` **health-gate + fleet `dns_server`** read `dns_endpoint` (VIP in HA) —
    one change, no mode branching. The `dig`-until-answers gate now targets the VIP.
  - `set-dns-all` / Traefik DNS rewrite recipes read `dns_rewrite_target` (origin in HA).
  - Scrape-target hot-push enumerates **both** nodes' exporters in HA mode
    (`tofu output -json hosts` → per-node `:9100/:9618/:9167`).
  - Add `just dns-failover-test centralized_dns` (kills AdGuard on the VIP holder over SSH,
    asserts the VIP moves + still resolves) and `just dns-sync-status centralized_dns`.
  - Add `just tail-log CLUSTER ROLE` (generalizes the existing `logs-k0s`/`logs-k0s-worker`
    hardcoded recipes into one parameterized live journal tail, using the shared
    `{{ssh_opts}}`/`{{ssh_key}}` — `logs-k0s`/`logs-k0s-worker` stay as-is, kept independently
    available for quick k0s feedback loops). Step 12's live HA bring-up backgrounds this per
    node before `just recreate`; see "Live provisioning watch" in Testing Strategy.

### 8. HA-aware CLI commands

- `adguard_cli.py`: accept multiple nodes (resolve all `hosts` IPs); add `sync-status`
  (query `primary`'s adguardhome-sync — its metrics/health endpoint if enabled, else parse
  its journal) and make `status`/`stats` able to fan out per node. `check` in HA mode asserts
  **both** nodes answer and the VIP answers.
- `_dns_common.py`: parse `dns_endpoint`/`hosts` so CLIs can target the VIP or individual nodes.

### 9. Hermetic tofu tests (`tests/tofu/`)

- Extend `sizing_and_render.tftest.hcl`:
  - `enable_ha = false` (default) → exactly one `multipass_instance` keyed `server`; rendered
    cloud-init contains **no** `keepalived` / `adguardhome-sync` tokens. **(Regression guard.)**
  - `enable_ha = true` (+ `vip_address`) → two instances `primary`/`secondary`; `primary`
    cloud-init contains `keepalived.conf` + `adguardhome-sync` + `state MASTER` + `priority 200`;
    `secondary` contains `state BACKUP` + `priority 100` and **no** `adguardhome-sync` unit;
    both contain `unicast_peer`; `dns_endpoint == var.vip_address`;
    `dns_rewrite_target == primary.ipv4`.
  - `enable_ha = true` with empty `vip_address` → the validation/precondition **fails** (plan errors).
- Keep the existing off-by-default cross-cluster assertions; pin `enable_ha = false` in the
  file-level `variables {}` of the existing tests so an auto-loaded tfvars can't flip them
  (the repo's documented `*.auto.tfvars` hazard).

### 10. Live testinfra tests (`tests/testinfra/`)

- `conftest.py`: build SSH targets from `hosts` for both `server` (single) and
  `primary`/`secondary` (HA); expose a `ha_mode` fixture from `enable_ha`/`vip_address`.
- Skip-unless-HA tests:
  - `test_keepalived.py` — `keepalived.service` active on both nodes; exactly one node holds
    the VIP (`ip addr | grep <vip>`); `chk_adguard.sh` exits 0 while AdGuard is up.
  - `test_sync.py` — `adguardhome-sync.service` active on `primary` only; add a rewrite via
    `primary`'s API, wait ≤ `sync_interval`, assert it appears on `secondary`'s API.
  - `test_failover.py` — the core HA assertion: `dig @<vip>` answers; `systemctl stop
    AdGuardHome` on the VIP holder; within ~5s the VIP is on the other node and `dig @<vip>`
    **still answers**; restart AdGuard and assert the VIP preempts back to `primary`.
- Existing single-mode tests run unchanged when `enable_ha = false`.

### 11. Docs

- `specs/cross-cluster.md` — amend the DNS signal row: fleet points at the **VIP** in HA
  mode; DNS-first ordering + health-gate now target `dns_endpoint`.
- `specs/centralized_dns.md` — add an "HA mode" cross-reference to this spec.
- Root `CLAUDE.md` "Clusters" section — note `centralized_dns` has an opt-in `enable_ha`
  mode (keepalived VIP + AdGuardHome-Sync), mirroring the `centralized_k0s` HA phrasing.
- `clusters/centralized_dns/{README.md,USAGE.md,DEFAULT_PASSWORDS.md}` — HA usage, the
  **"edit only on `primary`"** gotcha, the VIP address, VRRP creds (dev-throwaway), and the
  Task 1 spike findings.

### 12. Validate

- `just check centralized_dns` (hermetic, both `enable_ha` values via the tofu test runs).
- `tofu -chdir=clusters/centralized_dns fmt -check -recursive`.
- `just check <every cluster wired to dns_server>` — the fleet still resolves against
  `dns_endpoint`; nothing regressed.
- `uvx ruff check clusters/centralized_dns/scripts/*.py`; CLI hermetic suites
  (`tests/adguard`, `tests/unbound`, `tests/dns_common`).
- Live single-mode: `just up centralized_dns && just verify centralized_dns` (unchanged).
- **Before `just recreate`, start the live tail — first-class step, not an afterthought.** This
  is the single most failure-prone bring-up in the plan (VRRP-on-Multipass-NAT, the
  AdGuard-answering-before-keepalived-starts ordering gate, the arch-aware AdGuardHome-Sync
  binary fetch), so watch it live from the first `apply`, not after `just verify` goes red:
  ```bash
  just tail-log centralized_dns primary   > scratchpad/dns-primary.log   2>&1
  just tail-log centralized_dns secondary > scratchpad/dns-secondary.log 2>&1
  ```
  (Bash tool, `run_in_background: true` for each.) Then run `just recreate centralized_dns`.
  While it provisions, periodically:
  ```bash
  grep -iE "$(uv run tools/print_signatures.py)" scratchpad/dns-{primary,secondary}.log
  ```
  Treat any hit as stop-and-look, checked **during** provisioning. If a log goes quiet for
  **> 90s** while `uv run tools/system_debug.py centralized_dns --json` still shows
  `cloud_init_status: running` with no failed units/signatures, suspect the silent
  `until … sleep` wait-loop rather than assuming it's still working — `just ssh centralized_dns
  primary` (or `secondary`) then `ps -o pid,ppid,args -ax | grep -E 'runcmd|sleep'`.
  The two tails should show `keepalived[…]: VRRP_Instance(VI_DNS) Entering MASTER STATE` on
  `primary` and `BACKUP STATE` on `secondary` before proceeding past `just verify` to
  `just dns-failover-test` — if not, stop and look rather than continuing the sequence.
- Live HA: set `enable_ha=true`/`vip_address` (throwaway `.auto.tfvars`) → `just recreate
  centralized_dns` → `just verify centralized_dns` (failover + sync tests pass) →
  `just dns-failover-test centralized_dns`.
- Fleet: `just up-connected` (fleet points at the VIP) → `just verify-connected`.

## Testing Strategy

Two-layer split, HA-parameterized (mirrors the repo):

- **Hermetic** (`just check`, no VMs): `mock_provider "multipass" {}` + `command = plan`.
  Assert the mode fork — single mode renders exactly one `server` and **zero** HA tokens
  (regression guard for the ~5 fleet clusters already on `dns_server`); HA mode renders two
  role-tagged nodes, the correct MASTER/BACKUP keepalived config, unicast peering, the
  `primary`-only sync unit, and the `dns_endpoint`/`dns_rewrite_target` outputs. Assert the
  `vip_address`-required validation. CLI logic stays hermetic via pytest-httpserver.
- **Live** (`just verify` / `verify-connected`): testinfra over SSH. Single mode: existing
  suite. HA mode adds keepalived-holds-one-VIP, `primary`-only sync + rewrite-propagation,
  and the **failover test** (kill AdGuard on the VIP holder → VIP moves → VIP still resolves
  → preempts back). Fleet: a consumer resolves via the VIP; Prometheus scrapes both nodes.

Edge cases: VIP unreachable from the Mac host (Task 1 gate + documented fallback); unicast
peer IP churn after a `recreate` (peer IPs are runtime-injected like today's client render —
a recreate re-renders both, but note the VIP itself is *stable* by design, which is the whole
point); split-brain if VRRP advertisements are dropped on the bridge (both nodes claim the
VIP — the Task 1 spike must confirm advertisements actually flow, else split-brain is the
failure mode); AdGuardHome-Sync overwriting a hand-edit on `secondary` (documented: edit
`primary` only); sync version/schema drift between AdGuard versions on the two nodes (pin the
same AdGuard version on both — they boot from the identical seed).

### Live provisioning watch (complements, doesn't replace, the snapshot tools)

`tools/system_debug.py` is a **point-in-time** snapshot: a node stuck in a silent `until …
sleep` wait-loop (`triage-patterns` Example 4b — an early oneshot install failed under plain
`/bin/sh` with no `set -e`, so a later gate spins forever) reports `cloud-init: running`, no
failed units, no signature hits — indistinguishable from healthy-but-slow. A **live** tail is
the only thing that can tell "still working" from "silently stuck forever," because it sees log
*cadence* over time, not one snapshot.

- Start it **before** the Task 1 spike's VM launch / Step 12's `just recreate`, not after a
  failure surfaces.
- Mechanism: `just tail-log <cluster> <role>` (Step 12) or the equivalent raw `ssh … sudo
  journalctl -f -o short-iso -p warning` (Task 1, pre-cluster), backgrounded (Bash
  `run_in_background: true`) into `scratchpad/<cluster>-<role>.log`.
- Detection reuses `tools/_system_debug_core.SIGNATURES` via `tools/print_signatures.py` — no
  second hardcoded string list to drift out of sync.
- Stall detection: log-file mtime age (`date +%s` minus `date -r <file> +%s`) **> 90s** while
  `uv run tools/system_debug.py <cluster> [role] --json` still shows `cloud_init_status:
  running` with empty `failed_units`/`signature_hits` → suspect the silent wait-loop, ssh in and
  check `ps -o pid,ppid,args -ax | grep -E 'runcmd|sleep'` rather than continuing to wait.
- Not a replacement for `system_debug.py` / `triage-logs` / testinfra — it's what catches a
  problem *while `just recreate` is still running*, so those tools have a live-verified fact to
  check against instead of a cold trail once `just verify` finally reports it. Implements the
  "Background journalctl monitor" TODO in `specs/pki-and-dns.md`.

## Acceptance Criteria

- `enable_ha = false` (default): `just up centralized_dns` and `just check centralized_dns`
  produce the **current** single-`server` cluster with **no** keepalived/sync artifacts;
  every existing test and every `dns_server`-wired cluster passes unchanged.
- `enable_ha = true`: two VMs (`primary`, `secondary`), each running AdGuard + its own
  Unbound + exporters host-level under systemd; **no Docker** anywhere in the HA path.
- A single floating **VIP** answers DNS; the fleet's `dns_server` = the VIP.
- Killing `AdGuardHome` (or the VM) on the VIP holder moves the VIP to the healthy node in
  **< 5s** and `dig @<vip>` keeps answering; the VIP **preempts back to `primary`** when it
  recovers. The `vrrp_script` fails over on a *hung-but-running* AdGuard, not just a dead
  process.
- AdGuardHome-Sync runs on `primary` only; a rewrite/blocklist change on `primary` appears on
  `secondary` within `sync_interval`; `secondary` is never a config-edit target.
- `just set-dns-all` pushes rewrites to `primary` (origin), and they replicate to `secondary`
  — no clobber race with sync.
- `just verify centralized_dns` (both modes), `just verify-api centralized_dns`, and
  `just verify-connected` pass; `just check centralized_dns` passes hermetically for both
  `enable_ha` values.
- The Task 1 spike outcome (VIP reachable on Multipass, or the documented fallback) is
  recorded in the cluster README before Phase 2 code lands.

## Validation Commands

- `just check centralized_dns` — hermetic fmt + validate + tofu test (both HA modes).
- `tofu -chdir=clusters/centralized_dns fmt -check -recursive` — formatting gate.
- `tofu -chdir=clusters/centralized_dns test -test-directory=tests/tofu` — render/sizing +
  the HA fork + the `vip_address`-required validation.
- `just check centralized_logging && just check centralized_monitoring && just check centralized_pki && just check centralized_netbox && just check centralized_unifi` — fleet unaffected by the `dns_endpoint` switch.
- `uvx ruff check clusters/centralized_dns/scripts/*.py` — CLI lint.
- `cd clusters/centralized_dns/tests/adguard && uv run pytest -q` (+ `tests/unbound`, `tests/dns_common`) — hermetic CLI suites.
- Live HA (VMs up): `just recreate centralized_dns && just verify centralized_dns && just dns-failover-test centralized_dns`.
- Fleet (VMs up): `just up-connected && just verify-connected`.

## Notes

- **Precedent:** this is the DNS analogue of `centralized_k0s`'s opt-in etcd-quorum HA behind
  HAProxy — same `count`/`role` fan-out, same conditional edge, same "endpoint resolves to
  the edge in HA / the single node otherwise" output (`dns_endpoint` ≈ `k0s_api_ipv4`). Copy
  that module's structure; don't reinvent it.
- **New tools (versions pinned at implementation):**
  - **keepalived** — apt package (no version pin needed); unicast VRRP default for Multipass.
  - **AdGuardHome-Sync** — `github.com/bakito/adguardhome-sync`, **release binary** (not the
    Docker image), systemd unit. Pin a release; confirm a linux/arm64 asset exists (Multipass
    on Apple Silicon), else `go install` fallback like `unbound_exporter`.
- **The one thing to prove first:** the VIP on Multipass (Task 1). Everything else is routine
  repo mechanics; the VIP is the only genuine unknown. Do **not** skip the spike.
- **Config-edit discipline:** with unidirectional sync, **`primary` is the only place to edit
  config.** This must be loud in USAGE.md — an edit on `secondary` (e.g. someone hits the VIP
  when it happens to be on `secondary`) is silently reverted on the next sync. For admin UI
  access, use `primary`'s **real IP**, never the VIP.
- **Split-brain is the failure mode if VRRP advertisements don't flow** (both nodes think
  they're MASTER, both raise the VIP). The Task 1 spike's failover test (stop MASTER → VIP
  moves, restart → exactly one holder) is what proves advertisements actually reach the peer.
- **Background live tail is first-class from the start of bring-up, not reached for only after
  a failure:** for the first few iterations of both Task 1's spike and Step 12's live
  `recreate`, start the tail (`just tail-log centralized_dns primary`/`secondary`, or raw `ssh …
  journalctl -f` pre-cluster) **before** kicking off provisioning, backgrounded to
  `scratchpad/`. Mirrors the manual `logs-k0s`/`logs-k0s-worker` + `scratchpad/{ctl,wrk}.log`
  workflow already used for the k0s HA bring-up (`.team/centralized_k0s.backlog.md`) and closes
  out the documented-but-never-implemented TODO in `specs/pki-and-dns.md`. Grep it against
  `tools/print_signatures.py`'s output, never a hand-copied signature list. See "Testing
  Strategy → Live provisioning watch."
- **Secrets:** `vrrp_auth_pass` and the AdGuard admin password are **dev-throwaway lab**
  values (same posture as the existing AdGuard creds / NetBox token). Override via `TF_VAR_*`
  for anything real; regenerate the bcrypt seed hash when changing the AdGuard password.
- **`pre_tool_use` hook** matches substrings — avoid literal `rm `/`.env` tokens in commands
  while implementing (per root `CLAUDE.md`).
- **Recreate churns node IPs, not the VIP** — that's the design win: the fleet points at the
  stable VIP, so unlike today, rebuilding the DNS nodes no longer churns the address the fleet
  depends on. But editing HA cloud-init still needs `just recreate` (both nodes); during
  iteration, patch `/etc/keepalived/keepalived.conf` / the sync config over SSH and
  `systemctl restart`, then fold back into the `.tftpl`.
