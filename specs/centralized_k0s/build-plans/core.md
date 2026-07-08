# Build-plan: core (🏗) — Tofu root module for `clusters/centralized_k0s/`

## Task Description

Create the OpenTofu **root module** for a new greenfield cluster `clusters/centralized_k0s/`
implementing the multi-node k0s spec at `specs/centralized_k0s.md` (READ IT FIRST — the umbrella
spec is authoritative and WINS over the 5 shards in `specs/centralized_k0s/*.md`). You own **only**:

```
clusters/centralized_k0s/{main.tf, variables.tf, outputs.tf, providers.tf, versions.tf, terraform.tfvars}
```
plus **one edit** to the root `Justfile` (add the `command -v k0sctl` preflight gate).

You do **NOT** write cloud-init `.tftpl` files (node/k0sctl/vector own those) or tests (vector owns
`tests/**`). But your `main.tf` MUST reference the template paths those agents will create:
`cloud-init/{controller,worker,haproxy}.yaml.tftpl`, `cloud-init/k0sctl.yaml.tftpl`,
`cloud-init/vector/vector.toml.tftpl`. Reference them via `templatefile()`/`local_file` so the wiring
is ready when they land. Create empty-but-valid placeholder `.tftpl` files ONLY if needed to make
`tofu validate` pass before the other agents fill them — coordinate: prefer they exist. If you must
stub, write a minimal valid cloud-init (`#cloud-config\n{}`) and the owning agent overwrites it.

Target topology: **DEFAULT 1 controller + 2 workers, NO HAProxy**. HA `k0s_control_plane_count=3`
(3+3+HAProxy) must ALSO render correctly (hermetic test covers it) but is not the live target.

## Relevant Files (READ before writing)

- `specs/centralized_k0s.md` — authoritative. §"Provider & runtime-IP injection", §"Layout",
  the `hosts` output HCL block (lines ~70-78), §"Cluster bootstrap & join — k0sctl".
- `clusters/centralized_logging/{main.tf,variables.tf,outputs.tf,providers.tf,versions.tf}` — closest
  structural reference (server-first→ipv4→local_file render→cloudinit_file PATH edge).
- `clusters/centralized_monitoring/main.tf` — the **`terraform_data.k0s_log_shipper`** block at
  `:386` is your template for `terraform_data.k0s_bootstrap` (uses `provisioner "local-exec"` shelling
  to `ssh`/`scp`, `triggers_replace`, `local.ssh_opts` at `:17`). **Do NOT copy** the cloud-init
  `k0s install controller --single` lines — this cluster forms via k0sctl post-apply.
- `clusters/centralized_netbox/{main.tf,outputs.tf}` — the **count-gated conditional** `agent[0]`
  pattern (main.tf `:270`/`:301`, outputs.tf `:13`/`:28`) is your template for the conditional
  `haproxy` VM + conditional `hosts`/`dns_records` map entries.
- Root `Justfile` `:61` — the `up CLUSTER` recipe; there is **NO** existing tool preflight anywhere.

## Step-by-Step Tasks

1. **versions.tf / providers.tf** — pin `required_version >= 1.7`, `larstobi/multipass ~> 1.4`,
   `hashicorp/local ~> 2.4` (mirror `centralized_logging`). Provider block for multipass + local.

2. **variables.tf** — declare (with the spec's defaults):
   - `name_prefix` (default `"centralized-k0s"`), `ssh_pubkey_path`/`ssh_pubkey`, `image`.
   - `k0s_control_plane_count` (default **1**), `worker_count` (default **2**).
   - Per-role size objects `object({cpus=number,memory=string,disk=string})`:
     controller **3/3G/20G**, worker **2/4G/30G**, haproxy **1/1G/10G**.
   - `k0s_version` default **`"v1.34.9+k0s.0"`**.
   - `enable_cilium` (false), `enable_netdata` (true-ish per spec), `enable_netdata_ebpf` (false).
   - Cross-cluster opt-ins, **all empty-string/false defaults**: `dns_server`, `internal_ca_cert`,
     `ntp_server`, `log_shipping_target`, `openobserve_endpoint`, `openobserve_org`,
     `openobserve_password`, **`openobserve_stream`** (NEW — spec §"Var plumbing"), `domain`
     (default e.g. `"k0s.lab"`).
3. **main.tf**:
   - `locals`: `render_dir = "${path.module}/.rendered"`, `ssh_opts`, name maps, `k0s_api_host =
     "k0s-api.${var.domain}"`, and the **HA-size auto-bump** if desired (mirror spec sizing).
   - `multipass_instance.controller` **count = `var.k0s_control_plane_count`**, `worker`
     **count = `var.worker_count`**, `haproxy` **count = `var.k0s_control_plane_count > 1 ? 1 : 0`**.
     Names: `${name_prefix}-controller-${count.index+1}` etc. `cloudinit_file =
     local_file.<role>_ci[count.index].filename` (PATH, not inline).
   - `local_file` renders per role into `.rendered/` via `templatefile(<tftpl path>, {...})`. The
     controller/worker renders inject the Vector vars + `k0s_version` + resolver-gate vars +
     `k0s_api_host`. **Create-before-render edge:** the `k0sctl.yaml` render references
     `multipass_instance.controller[*].ipv4` and `worker[*].ipv4` (ALL of them) — this forces every VM
     created before the k0sctl render + bootstrap. (No "anchor node" — count instances create in
     parallel; the render referencing `[*].ipv4` is the real edge. See spec correction.)
   - `local_file.k0sctl` — render `cloud-init/k0sctl.yaml.tftpl` passing `controller_ips`,
     `worker_ips`, `k0s_version`, `k0s_api_host`, `ssh_key`, per-host `privateAddress` list. Written to
     `.rendered/k0sctl.yaml`.
   - **`terraform_data.k0s_bootstrap`** — model on monitoring `:386`. `triggers_replace` = all
     controller+worker ipv4 + `local_file.k0sctl.content`. `provisioner "local-exec"`: wait
     cloud-init on each host, `scp` the rendered `k0sctl.yaml` to a host (or run k0sctl from the Mac
     if k0sctl is local — prefer **local `k0sctl apply --config .rendered/k0sctl.yaml`** from the Mac
     since k0sctl SSHes to the hosts itself). **Fail-fast preflight inside it:** first line
     `command -v k0sctl >/dev/null || { echo "install k0sctl: brew install k0sproject/tap/k0sctl"; exit 1; }`.
   - **`terraform_data.k0s_kubeconfig_distribute`** and a **KSM manifest** step, each with
     **`depends_on = [terraform_data.k0s_bootstrap]`** so they never run before the cluster exists.
     kubeconfig: pull admin config (its `server:` already = `k0s-api.<domain>`) and scp to
     `/home/ubuntu/.kube/config` on every node.
4. **outputs.tf** — `hosts` (dynamic map, HAProxy count-gated via `merge(..., cond ? {haproxy=...} :
   {})` exactly like the spec block), `k0s_api_endpoint`, `dns_records` (**include
   `k0s-api.<domain>` → HAProxy IP in HA mode / controller-1 IP in single mode**), `web_urls`
   (`{core, all}`, flag-aware — HAProxy `:8405/metrics` in `all` when HA). Also a
   `cross_cluster_enabled`-style bool output if tests need it for skip-guards (coordinate w/ vector).
5. **terraform.tfvars** — pin the live defaults (1 CP + 2 workers, image, ssh key path). Keep opt-ins
   empty so a plain `just up` is turnkey.
6. **Justfile edit** — add a `command -v k0sctl` **preflight gate** as the first body line of the `up`
   recipe (root `Justfile` `:62`), guarded to the k0s cluster (only enforce when
   `CLUSTER == "centralized_k0s"`, e.g. `@if [ "{{CLUSTER}}" = "centralized_k0s" ]; then command -v
   k0sctl >/dev/null || { echo "install k0sctl: brew install k0sproject/tap/k0sctl"; exit 1; }; fi`).
   Do not disturb other clusters. This is your ONLY Justfile edit.

## Validation Commands

```sh
tofu -chdir=clusters/centralized_k0s fmt
tofu -chdir=clusters/centralized_k0s validate     # needs the .tftpl files to at least exist
just check centralized_k0s                          # hermetic — will fully pass once vector's tests land
```
(`validate` needs the referenced `.tftpl` paths to exist. If node/k0sctl/vector haven't landed them
yet, `fmt` + a structural self-review is enough for your TASK-DONE; full `just check` is the
integration gate the LEAD runs.)

## Acceptance Criteria

- `tofu fmt` clean; `tofu validate` passes (given placeholder-or-real `.tftpl` files).
- Default renders 1 controller + 2 workers, **no haproxy**; `k0s_control_plane_count=3` renders 3
  controllers + 3 workers + 1 haproxy.
- `hosts` output is the dynamic count-gated map; `dns_records` includes `k0s-api.<domain>`.
- `terraform_data.k0s_bootstrap` exists (local-exec k0sctl apply + fail-fast k0sctl preflight);
  `k0s_kubeconfig_distribute` + KSM manifest have `depends_on = [terraform_data.k0s_bootstrap]`.
- **NO** `k0s install`/`k0s start`/any API-dependent step in your HCL (that's cloud-init's job and
  it's forbidden there too).
- Justfile `up` gains the guarded `command -v k0sctl` preflight; no other cluster affected.

## Rules (repo CLAUDE.md — obey)

- Edit ONLY your 6 files + the one Justfile recipe. Never touch `.rendered/` (re-rendered each apply).
- A newly-added `output` errors "not found" until one `tofu apply` runs (outputs-only, safe) — fine.
- Keep your tab pill current on every step:
  `cmux rename-tab --surface 4ADFB530-0EE9-450A-830F-7A3FD6E4FC92 "🔵 core <n>/<N> [<bar>] · <log>"`
  (🔵 working / 🟢 done / 🔴 error). End with `TASK-DONE: core | <summary>` on its own line.
