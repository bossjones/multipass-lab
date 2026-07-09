# Build-plan: node (📦) — controller + worker cloud-init

## Task Description

Write the OS-prep cloud-init templates for the k0s controller and worker VMs of
`clusters/centralized_k0s/`. READ `specs/centralized_k0s.md` FIRST (authoritative). You own **only**:

```
clusters/centralized_k0s/cloud-init/controller.yaml.tftpl
clusters/centralized_k0s/cloud-init/worker.yaml.tftpl
```

**CRITICAL HARDENING (spec §"Cluster bootstrap" + §"Boot-race hardening"):** cloud-init does **OS
prep ONLY**. It must run **NO `k0s install`, NO `k0s start`, and NO API-dependent step** (no
`k0s kubectl … /readyz`, no KSM/ingress/kubeconfig). k0sctl (owned by the k0sctl agent + core's
`terraform_data.k0s_bootstrap`) forms the cluster post-apply. Copying the single-node templates would
drag in an `until … /readyz; do sleep 5; done` against a cluster that doesn't exist yet → the
canonical **infinite cloud-init hang** (`multipass launch` never returns). Do NOT.

## Relevant Files (READ before writing)

- `specs/centralized_k0s.md` — §"Boot-race hardening", §"Node tooling & shell UX", §"Observability",
  the exporter table (node/systemd/process 9100/9558/9256, kubelet RO 10255, cAdvisor 8089, etcd
  2381 on controllers, netdata 19999), §"CNI".
- `clusters/centralized_monitoring/cloud-init/k0s-client.yaml.tftpl` — the resolver-gate block
  (`:216-225`) and the bounded-retry install loop. **AVOID** its `:234` `k0s install controller
  --single` / `k0s start` lines.
- `clusters/centralized_logging/cloud-init/docker-client.yaml.tftpl` `:277` — the resolver warm-up
  gate idiom (`systemctl restart systemd-resolved` + `for i in $(seq 1 30); getent hosts … && break`).
- `clusters/centralized_netbox/cloud-init/server.yaml.tftpl` — the **post-boot systemd oneshot**
  (`--no-block`) pattern: the unit at `:365`, `systemctl start --no-block` at `:458`, the ExecStart
  script re-gating DNS at `:251`, and a **readiness marker** file (`/var/lib/.../done`) testinfra polls.
- `specs/centralized_k0s/tooling-shell-repo.md` + `provisioning-cloudinit.md` shards (backing detail;
  umbrella wins on versions — kubectl v1.34.x, helm v3.21.2, k9s v0.51.0, stern v1.34.0, etcdctl 3.6.x).

## Step-by-Step Tasks

Both templates share most structure; differ by role flags. Parameterize via `templatefile` vars that
core passes (`k0s_version`, `dns_server`, `internal_ca_cert`, `ntp_server`, `enable_netdata`,
`ssh_pubkey`, the rendered `vector_toml` content or path, `k0s_api_host`, role).

1. **Header + users + SSH** — `#cloud-config`, `package_upgrade: false` (300s window!), inject
   `ssh_pubkey` for `ubuntu`, write files.
2. **UNCONDITIONAL resolver warm-up gate** in `runcmd` — NOT gated on `dns_server != ""` (spec: make
   it unconditional). `systemctl restart systemd-resolved` then warm the actual hosts hit:
   ```
   for h in get.k0s.sh github.com raw.githubusercontent.com get.helm.sh; do
     for i in $(seq 1 30); do getent hosts "$h" >/dev/null 2>&1 && break; sleep 2; done
   done
   ```
3. **Pinned k0s binary install** (NOT `k0s install`) — bounded retry, so the binary is present for
   k0sctl to use:
   ```
   for i in $(seq 1 5); do curl -sSLf https://get.k0s.sh | K0S_VERSION=${k0s_version} sh && break; sleep 5; done
   ```
   Do **not** run `k0s install`/`k0s start`.
4. **CA trust (opt-in)** — if `internal_ca_cert != ""`, drop into
   `/usr/local/share/ca-certificates/` + `update-ca-certificates` (the repo's gated `write_files`
   idiom; mirror other clusters).
5. **Move heavy work into a post-boot systemd oneshot** (`k0s-nodeprep.service`, Type=oneshot,
   `--no-block`, RemainAfterExit=yes, TimeoutStartSec=0) whose ExecStart script **re-gates DNS first**
   (the `--no-block` races the resolver), then does, each in a **bounded** `for i in $(seq 1 5)` retry:
   - `install-cli.sh`-style arch-substituted release installs into `/usr/local/bin`: **kubectl**
     (v1.34.x), **helm** (v3.21.2, unconditional), **k9s** (v0.51.0), **stern** (v1.34.0), **etcdctl**
     (3.6.x). Wrap every GitHub/get.helm.sh fetch in bounded retry.
   - **oh-my-zsh** unattended as `ubuntu` (`RUNZSH=no CHSH=no KEEP_ZSHRC=yes`), `chsh -s $(which zsh)
     ubuntu`, one `~/.oh-my-zsh/completions/_<tool>` per tool (`etcd,kubectl,helm,stern,k9s,k0s`).
   - **Exporters** (node 9100 / systemd 9558 / process 9256 everywhere; **controller also**: kubelet
     RO 10255 via `--read-only-port`, cAdvisor 8089 v0.49.1, etcd metrics 2381). Wrap fetches bounded.
   - **Netdata** if `enable_netdata` (`enable_netdata_ebpf` OFF on arm64). Bounded retry.
   - Drop a **readiness marker** `/var/lib/k0s-nodeprep/done` at the end (testinfra + fixtures poll it).
6. **Vector** — core passes the rendered Vector config; write it to disk + install/enable the Vector
   agent in the oneshot (the vector agent owns the config CONTENT; you own placing + running it on the
   node). Coordinate: expect a `vector_toml` template var or a rendered file path from core.
7. **controller.yaml.tftpl vs worker.yaml.tftpl differences:**
   - Controller: also lay down kubelet-RO / cAdvisor / etcd-metrics exporters. The `--enable-worker`
     + taint is a **k0sctl `installFlags`** concern (k0sctl agent), NOT a cloud-init concern — do not
     add k0s runtime flags here.
   - Worker: node/systemd/process exporters + netdata + vector only (no etcd/kubelet-RO-extra).
8. **NTP** (opt-in `ntp_server`) per repo idiom if set. Note Multipass injects HOST tz at first boot.

## Validation Commands

```sh
# hermetic render check (vector agent's test asserts these; you can self-check the YAML validity):
tofu -chdir=clusters/centralized_k0s validate
just check centralized_k0s     # once core + tests land
# live (ops runs later): cloud-init reaches `done` fast; marker /var/lib/k0s-nodeprep/done appears
```

## Acceptance Criteria

- Both templates are valid `#cloud-config` YAML (`can(yamldecode(...))` will be asserted hermetically).
- **NO** `k0s install`, `k0s start`, or any API-dependent/`/readyz` wait anywhere.
- Resolver warm-up gate is **UNCONDITIONAL**; **every** network fetch is a **bounded** `for i in
  $(seq 1 5/30)` retry — **no unbounded `until … ; do sleep; done`**.
- `package_upgrade: false`; heavy tool/exporter/netdata/vector installs are in a post-boot
  `--no-block` oneshot that re-gates DNS and drops `/var/lib/k0s-nodeprep/done`.
- Controller template lays down kubelet-RO/cAdvisor/etcd exporters; worker does not.
- k0s **binary** present (`get.k0s.sh` pinned to `${k0s_version}`) but NOT installed as a service.

## Rules

- Edit ONLY your 2 files. Never touch `.rendered/`. After any `.tftpl` edit the live redeploy is
  `just recreate` (ops runs it), never `just up`.
- Keep tab pill current every step:
  `cmux rename-tab --surface EA732F3D-6058-467D-B811-3E3739086554 "🔵 node <n>/<N> [<bar>] · <log>"`.
  End with `TASK-DONE: node | <summary>`.
