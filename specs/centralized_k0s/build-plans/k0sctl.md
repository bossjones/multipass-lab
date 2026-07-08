# Build-plan: k0sctl (⚙️) — k0sctl cluster config + HAProxy edge

## Task Description

Write the k0sctl cluster-formation config and the conditional HAProxy edge cloud-init for
`clusters/centralized_k0s/`. READ `specs/centralized_k0s.md` FIRST (authoritative). You own **only**:

```
clusters/centralized_k0s/cloud-init/k0sctl.yaml.tftpl
clusters/centralized_k0s/cloud-init/haproxy.yaml.tftpl
```

## Relevant Files (READ before writing)

- `specs/centralized_k0s.md` — §"Cluster bootstrap & join — k0sctl" (the hardening bullets are
  binding), §"Control-plane HA + load balancer (HAProxy, conditional)" (the HAProxy config sketch +
  `:8405` prometheus frontend), §"Version pin", the Decisions table.
- `specs/centralized_k0s/ha-loadbalancer.md` + `provisioning-cloudinit.md` shards (backing detail;
  umbrella wins).
- k0sctl config reference: https://docs.k0sproject.io/stable/ (use Context7/docs if unsure of schema).
- core's `main.tf` will render this template passing: `controller_ips` (list), `worker_ips` (list),
  `k0s_version`, `k0s_api_host` (= `k0s-api.<domain>`), `ssh_user`(ubuntu), `ssh_key_path`, and the
  haproxy IP when HA. Confirm the exact var names with core (surface
  `4ADFB530-0EE9-450A-830F-7A3FD6E4FC92`).

## Step-by-Step Tasks — k0sctl.yaml.tftpl

Render **ONE shared cluster config** for BOTH modes (1 CP and 3 CP) — NOT per-controller `k0s.yaml`.

1. `apiVersion: k0sctl.k0sproject.io/v1beta1`, `kind: Cluster`. `spec.hosts` is a Tofu-templated loop
   over controllers then workers.
2. **Per-host, pin `privateAddress` explicitly** to the tofu-discovered `ipv4` (`%{ for ip in
   controller_ips }` …). Do **NOT** rely on k0sctl fact-gathering — it can pick a CNI bridge
   `10.244.x` iface → SAN/etcd-peer mismatch → silent TLS/quorum failure. Each host:
   `ssh: {address: <ip>, user: ubuntu, keyPath: <key>}`, `privateAddress: <ip>`,
   `installFlags: [...]`, `role: controller|worker`.
3. **Role via `installFlags`, not config fields.** Controllers get **`--enable-worker`** (keep the
   control-plane taint — do NOT add `--no-taints`) so kubelet/cAdvisor + pod logs land, no user pods.
   Also `role: controller` (k0sctl role). Workers `role: worker`.
4. **`spec.k0s.version: ${k0s_version}`** and **`spec.k0s.config`** (embedded ClusterConfig):
   - `spec.storage.type: etcd` **UNCONDITIONALLY** (both modes; single-member when 1 CP). Do NOT use
     kine/sqlite. This is the hermetic assertion — must be `etcd` in the 1-CP render too.
   - `spec.api.externalAddress: ${k0s_api_host}` (the **hostname** `k0s-api.<domain>`, NOT a DHCP IP —
     backup/restore footgun fix). `spec.api.sans:` include every controller IP + `k0s_api_host`.
   - `spec.network.provider: kuberouter` (v1 default; `enable_cilium` is iteration 2, not here).
     Keep k0s default `podCIDR 10.244.0.0/16` / `serviceCIDR 10.96.0.0/12`.
   - In **single-CP** mode `externalAddress` resolves to controller-1; in **HA** to the HAProxy IP —
     driven by `dns_records` (core owns) so the template just uses `k0s_api_host` either way.
5. Do **NOT** embed KSM/any manifest here that needs the API at bootstrap — the manifest deployer /
   post-apply `terraform_data` (core) handles KSM. (You MAY use `spec.k0s.config` manifest deployer
   dir only if it's declarative and API-independent; prefer leaving KSM to core's post-apply step to
   match the spec.)

## Step-by-Step Tasks — haproxy.yaml.tftpl (rendered ONLY when `k0s_control_plane_count > 1`)

1. `#cloud-config`, `package_upgrade: false`, install haproxy (bounded-retry apt or pinned).
   Unconditional resolver gate (same idiom as node's templates) before any fetch.
2. **L4 passthrough** (`mode tcp`) frontends/backends for **6443** (apiserver), **8132**
   (konnectivity), **9443** (controller join) → all controllers (`option tcp-check`, `balance
   roundrobin`, per-controller `server` lines from `controller_ips`).
3. **Native Prometheus exporter** frontend on **:8405** (no sidecar):
   ```
   frontend prometheus
     bind :8405
     mode http
     http-request use-service prometheus-exporter if { path /metrics }
     no log
   ```
4. Write `/etc/haproxy/haproxy.cfg` via `write_files`, `systemctl enable --now haproxy` (or restart).
   Keep it simple; no post-boot oneshot needed unless a fetch is involved.

## Validation Commands

```sh
tofu -chdir=clusters/centralized_k0s validate
just check centralized_k0s     # hermetic asserts: k0sctl.yaml has storage.type: etcd (both modes),
                               # per-host privateAddress, --enable-worker on controllers,
                               # externalAddress: k0s-api.<domain>; HA render has haproxy :8405 frontend
# live k0sctl dry check (ops, later): k0sctl apply forms the cluster; k0s status Running
```

## Acceptance Criteria

- **ONE** `k0sctl.yaml` (no per-controller `k0s.yaml`). Valid YAML (`can(yamldecode(...))`).
- `storage.type: etcd` in **both** the 1-CP and 3-CP renders.
- Every host has an explicit `privateAddress` = its tofu ipv4; controllers carry `--enable-worker`
  in `installFlags` **with the taint kept** (no `--no-taints`).
- `spec.api.externalAddress` = `k0s-api.<domain>` (hostname); SANs include all controllers + that host.
- HAProxy template renders only in HA mode, passes 6443/8132/9443 at L4, exposes `:8405/metrics`
  via the native `prometheus-exporter` service.
- NO API-dependent bootstrap embedded that would run before the cluster exists.

## Rules

- Edit ONLY your 2 files. Never touch `.rendered/`. After edits, redeploy is `just recreate` (ops).
- Confirm the `templatefile` var names with **core** before finalizing (don't guess — align).
- Keep tab pill current every step:
  `cmux rename-tab --surface AF1C1F20-33EC-4C27-959B-6C6984E34335 "🔵 k0sctl <n>/<N> [<bar>] · <log>"`.
  End with `TASK-DONE: k0sctl | <summary>`.
