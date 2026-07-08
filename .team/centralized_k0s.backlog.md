# centralized_k0s — LEAD backlog

FSM: `SCAFFOLD → BUILD(core→node|k0sctl|vector) → CHECK → UP → OBSERVE → {HEALTHY→VERIFY→DONE} | {ISSUE→FIX-LIVE→BACKPORT→RECREATE→OBSERVE↺} | ERROR`

Authoritative spec: `specs/centralized_k0s.md` (umbrella WINS over the 5 shards).
Target: DEFAULT 1 controller + 2 workers (no HAProxy). HA 3+3 is a later opt-in.

## Now — ✅ COMPLETE (fsm=DONE, GREEN FROM SOURCE)
- [x] Read spec, fsm=SCAFFOLD, 4 build-plans
- [x] Dispatch core (barrier) → fan out node | k0sctl | vector
- [x] `just check` hermetic-green (9/9)
- [x] `just up` → OBSERVE → fix-running-first (20 passed via live patches)
- [x] Backport ALL 7 source fixes (5 original + #6 konnectivity + #7 resolv.conf hardening)
- [x] Batched `just recreate` → Apply complete (10 added) → `just verify`
      **24 passed / 25 skipped / 0 failed — GREEN FROM SOURCE, no live patches.**
      New functional tests PASSED: konnectivity_agents_ready, metrics_api_serves_node_metrics,
      coredns_pods_ready, coredns_no_plugin_loop. Independent LEAD SSH check: 3/3 nodes Ready,
      konnectivity 3×1/1 (0 restarts), `kubectl top nodes` metrics, CoreDNS plugin/loop=0.

## Open issues (from OBSERVE)
- 🔴 **ENV BLOCKER (not our code): multipassd socket down.** `just up` failed because
  `multipass list` → "cannot connect to the multipass socket". Verified: `/var/run/multipass_socket`
  is MISSING; a stray `multipassd --verbosity debug` (pid 93751) is running but not binding the
  launchd socket; all 13 other-cluster QEMU VMs are still alive. **I cannot fix it — `sudo` requires a
  password (no askpass/TTY).** Needs the HUMAN (sudo/GUI):
  `sudo launchctl kickstart -k system/com.canonical.multipassd` (recreates the socket), or quit+reopen
  Multipass.app. A premature "socket's up now" was in ops's buffer but the socket is verified STILL
  DOWN. Ops must NOT re-run `just up` until `multipass list` succeeds. Build is CHECK-green and parked.
  - ✅ **RESOLVED** — human fixed multipassd on the side; `multipass list` works, socket up, no k0s
    orphans, tofu state clean (2 local_file renders only). LEAD green-lit ops → re-running `just up`.
- 🟡 **CLEAN-SLATE (user directive):** all 3 k0s VMs came up `State=Unknown` / no IPv4 — a broken-VM
  state a re-up won't fix (fresh `just up` would collide). LEAD killed the stuck in-flight
  `just up`→`tofu apply` chain (pids 41790/41797/41933), cleared the stale lock; the killed apply left
  a **0-byte `terraform.tfstate`** so tofu tracks nothing but the 3 Unknown VMs remain as orphans.
  Recovery routed to ops: `just destroy centralized_k0s` (tofu destroy + **prune** the Unknown VMs) →
  confirm `multipass list` clear of `centralized-k0s-*` → fresh `just up`. If any k0s VM returns
  `Unknown` after that, it's a REAL boot/launch failure to triage (system-debug + cloud-init-output.log),
  not transient.
  - ✅ **Clean-slate WORKED** — destroy+prune cleared the orphans; fresh `just up` launched all 3 VMs
    **Running** with IPs (controller-1 .168 / worker-1 .169 / worker-2 .170). Ops now in OBSERVE:
    checking `cloud-init status --long` + driving `just verify`.
- 🔴 **REAL ISSUE — k0sctl `--disable-telemetry` flag obsolete → cluster never forms.** All 3 VMs'
  cloud-init reached `status: done` (no failed units; "degraded" is only a benign cloud-config schema
  WARNING). The failure is host-side in `terraform_data.k0s_bootstrap`'s `local-exec`:
  - `main.tf:209` runs `k0sctl apply --config .../k0sctl.yaml --disable-telemetry`
  - installed k0sctl is **v0.32.1**, which does NOT define that flag (removed upstream; not global, not
    on `apply`, no env var). Cited fatal lines from the `just up` log:
    - `Incorrect Usage: flag provided but not defined: -disable-telemetry`
    - `level=fatal msg="flag provided but not defined: -disable-telemetry"`
  - `just up` aborts at line 209 → `k0s_kubeconfig_distribute` + `k0s_ksm_manifest` never run → no cluster.
  - **Fix (owner = k0sctl builder, `clusters/centralized_k0s/main.tf:209`):** drop ` --disable-telemetry`
    (telemetry is already off by default in modern k0sctl). This is a root-module `local-exec`, NOT a
    cloud-init `.tftpl` — the redeploy after the backport is a plain **`just up`** (re-runs the 3
    `terraform_data` provisioners against the healthy, still-Running VMs; NO `just recreate`, no VM churn).
  - **Ops live-unblock (no source touched):** running the 3 provisioners' commands by hand
    (k0sctl apply w/o the flag → kubeconfig distribute → ksm manifest) to form the cluster and drive
    `just verify` green now. Backport still required so `just up`/`recreate` are green unattended.
- 🔴 **REAL ISSUE — k0s-api endpoint unresolvable on a plain `just up` → workers can't join.**
  k0sctl config sets `spec.api.externalAddress: k0s-api.k0s.lab` (a hostname) and the worker join
  token targets `https://k0s-api.k0s.lab:6443`. But a plain `just up` never registers DNS (that's
  `set-dns-all` in up-connected) and NO cloud-init `/etc/hosts` fallback exists, so nodes can't
  resolve it. Cited k0sctl fatal:
  - `failed to connect to kubernetes api using the join token - check networking: ... Unable to
    connect to the server: dial tcp: lookup k0s-api.k0s.lab on 127.0.0.53:53: no such host` (×2 workers)
  - Also breaks host-side `kubectl`/testinfra using the distributed kubeconfig (Mac can't resolve it either).
  - **Fix (owner = node builder cloud-init, `worker.yaml.tftpl`/`controller.yaml.tftpl`; coupled to
    k0sctl builder's externalAddress choice):** add a `write_files`/runcmd `/etc/hosts` entry
    `<controller-1 ipv4> k0s-api.<domain>` on every node at first boot (runtime-IP-injection pattern),
    so the stable hostname resolves offline without the DNS hub. `.tftpl` change → redeploy `just recreate`.
  - **Ops live-unblock:** appended `192.168.252.168 k0s-api.k0s.lab` to `/etc/hosts` on all 3 nodes.
- 🔴 **REAL ISSUE — Vector never installed/started on a plain `just up` (test asserts it always runs).**
  `test_vector.py::test_vector_service_running` docstring: *"Vector runs on every node (installed
  unconditionally — collection is always on)"*, and `/etc/vector/vector.toml` is written
  unconditionally. But TWO gates defeat that when cross-cluster is unwired:
  1. **Install gated:** `worker.yaml.tftpl:179` / `controller.yaml.tftpl` wrap the vector
     download+`vector.service`+`enable --now` in `%{ if log_shipping_target != "" || openobserve_endpoint
     != "" ~}` → on a plain `just up` (both empty) the binary + unit are never created. Deployed
     `/usr/local/sbin/k0s-nodeprep.sh` has NO vector block; `command -v vector` empty; `vector.service`
     = "not-found".
  2. **Config has zero sinks when unwired:** `vector.toml` ends at `# --- Sinks ---` with nothing after
     (all sinks gated on target vars). Even with the binary, vector can't start — dangling transforms
     (`host_syslog_fields`,`pod_meta`) + no sink = config-invalid.
  - **Fix (owner = vector builder):** (a) ungate the install block so the binary+service are always
    present; (b) render a fallback local sink (e.g. `blackhole` consuming both transforms) when no
    shipping target is wired, so the config always validates and the service stays active. `.tftpl`
    change → redeploy `just recreate`.
  3. **`${var}` in the config comments breaks Vector env-interpolation:** `vector.toml` lines 6 & 8
     contain literal `${var}`/`${}` in prose comments. Vector interpolates `${...}` across the WHOLE
     file (comments included) → `Configuration error ... Missing environment variable ... name = "var"`
     (`status=78/CONFIG`, crash-loop). Would break the WIRED path too — config was never `vector validate`d.
     Fix: escape as `$${var}` (Vector literal-`$`) or drop the `${}` from the comment.
  4. **Fallible VRL assignment in `pod_meta`:** `.appname = parsed.namespace + "/" + parsed.container`
     → `error[E103]: unhandled fallible assignment` (nullable capture groups). Fix: error-capturing
     form `.appname, err = parsed.namespace + "/" + parsed.container` (validated clean).
  - **Ops live-unblock:** install vector v0.44.0 + `blackhole` fallback sink + `vector.service` +
    escape `${`→`$${` in comments + error-capturing `.appname` VRL. `vector validate` = Validated,
    service **active** on all 3 nodes. All four sub-fixes must land in the vector `.tftpl`s for a
    clean `just recreate`.
- 🟡 **REAL ISSUE (cosmetic, breaks a test) — etcdctl zsh completion filename mismatch.**
  `worker.yaml.tftpl:164` / `controller.yaml.tftpl` write `etcdctl completion zsh > "$ZC/_etcd"`, but
  `test_zsh_default_shell_with_completions` (and zsh convention for command `etcdctl`) expect
  `_etcdctl`. Cited: `AssertionError: zsh completion _etcdctl missing on controller-1`.
  - **Fix (owner = node builder):** rename the target to `"$ZC/_etcdctl"`. `.tftpl` change → `just recreate`.
  - **Ops live-unblock:** `cp _etcd _etcdctl` (chown ubuntu) on all 3 nodes.
- 🔴 **REAL ISSUE #6 (missed by verify!) — konnectivity tunnel DOWN → metrics API 503.** CONFIRMED on
  controller-1: all 3 `konnectivity-agent-*` pods `0/1 Running` for 74m (`kubectl get pods -A`), so the
  konnectivity tunnel is down → kube-apiserver can't reach kubelet/metrics-server → `metrics.k8s.io/v1beta1`
  returns **503 "No agent available"** (spamming k0s logs; metrics-server: `Get
  https://192.168.252.168:10250/containerLogs/... No agent available`). No `kubectl top`, no metrics API.
  (Benign/ignore: v1 Endpoints deprecation, etcd compaction, "no RequestInfo".)
  - **Root cause = IN-CLUSTER facet of issue #2.** `externalAddress: k0s-api.k0s.lab`; the konnectivity
    AGENTS are **pods** that resolve via **CoreDNS**, which has **no record** for `k0s-api.k0s.lab`. The
    live `/etc/hosts` patch was on the NODES — pods don't use node `/etc/hosts`. So agents can't dial the
    endpoint → tunnel never establishes.
  - **Fix (owner = k0sctl builder** — externalAddress/konnectivity; node if a cloud-init facet is needed):
    make `k0s-api.<domain>` resolvable **in-cluster** — a CoreDNS `hosts`/rewrite entry → controller-1 IP
    (single-CP), OR point konnectivity/externalAddress at a resolvable IP for single-CP mode. Consult k0s
    docs for the k0s-native CoreDNS customization (manifest/clusterconfig that survives reconcile).
  - **FIX-RUNNING-FIRST:** SSH-apply live on the running cluster and VERIFY `konnectivity-agent` pods go
    **1/1 Ready** AND `kubectl top nodes` returns 200/data, BEFORE backporting into source.
  - **Test gap (owner = VECTOR):** `just verify` passed 20/20 while this was broken. ADD testinfra
    assertions: (a) all `konnectivity-agent-*` pods Ready; (b) `kubectl top nodes` works (metrics API 200).
    So "green from source" means FUNCTIONAL, not just "nodes Ready".
  - **Live-watch gate (ops, user directive):** ops keeps `journalctl -f` tails running per role across
    OBSERVE/recreate/verify — `just logs-k0s` (controller-1) + `just logs-k0s-worker` (worker-1),
    backgrounded to `scratchpad/{ctl,wrk}.log` and tailed. CONFIRMED running (ctl.log 47.5K/wrk.log
    45.5K, live). The controller tail must show the `No agent available`/503 spam STOP + konnectivity-agent
    1/1 AFTER k0sctl's live patch — that live confirmation is the gate BEFORE k0sctl backports.
  - ✅ **#6 FIXED (live-verified):** k0sctl set `externalAddress` → controller IP `192.168.252.168`
    (single-CP). `kubectl top nodes` returns data, konnectivity-agents 1/1, CoreDNS 1/1 0 restarts.
    **Keep this fix; backport into k0sctl.yaml.tftpl.**
- 🟡 **ISSUE #7 (hardening, latent trap — k0s docs) — resolv.conf stub → CoreDNS loop risk.** Nodes'
  `/etc/resolv.conf` = `nameserver 127.0.0.53` (systemd-resolved STUB). Per k0s docs
  (troubleshooting#coredns-in-crash-loop) the stub causes CoreDNS `plugin/loop: Loop detected`
  crashloops. Not looping now, but latent. Real upstream `/run/systemd/resolve/resolv.conf` EXISTS on
  the nodes.
  - **LEAD DECISION = Option (a):** set kubelet `--resolv-conf=/run/systemd/resolve/resolv.conf` via the
    k0sctl config (worker-profile `resolvConf`, or `--kubelet-extra-args` in installFlags) so ALL pods
    (incl. CoreDNS) get the real upstream, breaking the stub loop at the root. Owner = **k0sctl**.
    (Rejected (b) `spec.network.coreDNS.patches` — fixes only CoreDNS, not all pods.)
  - **FIX-RUNNING-FIRST:** apply live, SSH-verify CoreDNS stays 1/1 with NO `plugin/loop` in logs, then
    backport into k0sctl.yaml.tftpl.
  - **Test (owner = VECTOR):** CoreDNS pods Ready + no `plugin/loop` in coredns logs + `kubectl top
    nodes` returns rows → green-from-source proves DNS is durable.
- 🔴 **ISSUE #8 (BLOCKS recreate — incomplete #6 backport) — `templatefile` vars map missing
  `k0s_api_ipv4`.** The batched `just recreate` aborted at the FIRST step (`tofu destroy`) — config
  won't even evaluate. The k0sctl `#6` backport made `cloud-init/k0sctl.yaml.tftpl:76` reference
  `externalAddress: ${k0s_api_ipv4}`, but the `local_file.k0sctl` `templatefile()` call in **`main.tf:186`**
  passes only `{controller_ips, worker_ips, k0s_version, k0s_api_host, ssh_key, ha_mode}` — **no
  `k0s_api_ipv4`**. Cited:
  - `Error: Invalid function argument ... on main.tf line 186, in resource "local_file" "k0sctl"`
  - `Invalid value for "vars" parameter: vars map does not contain key "k0s_api_ipv4", referenced at
    ./cloud-init/k0sctl.yaml.tftpl:76,30-42`
  - The local ALREADY EXISTS: `main.tf:28  k0s_api_ipv4 = local.ha_mode ? haproxy[0].ipv4 :
    controller[0].ipv4` — and core already wired it into the WORKER render (`main.tf:124 k0s_api_ip =
    local.k0s_api_ipv4`), just NOT into the k0sctl render.
  - **Fix (owner = core builder, `main.tf:186` templatefile vars map):** add
    `k0s_api_ipv4 = local.k0s_api_ipv4`. One line. Then re-run `just recreate`.
  - **Impact:** nothing was destroyed/rebuilt — the old live-patched cluster (.168/.169/.170) is still
    up and tofu still tracks it. NOT self-patched by ops (source fix, routed to core per "green from source").
  - ✅ **RESOLVED (core, main.tf:191):** `k0s_api_ipv4 = local.k0s_api_ipv4` added to the k0sctl
    templatefile vars. `just check` 9/9 hermetic-green, and the batched `just recreate` then ran clean.
- ✅ **GREEN FROM SOURCE — batched `just recreate` + `just verify` (NO live patches this round).**
  Recreate: `Apply complete! 10 added`, all 3 VMs Running (controller-1 .171 / worker-1 .173 / worker-2 .172),
  k0sctl formed the cluster with `k0sctl apply` (NO `--disable-telemetry`, NO `k0s_api_ipv4` error),
  "k0s cluster version v1.34.9+k0s.0 is now installed" (Finished 1m6s). `just verify` = **24 passed,
  25 skipped, 0 failed.** The 4 new functional assertions all PASS:
  `test_konnectivity_agents_ready`, `test_metrics_api_serves_node_metrics`, `test_coredns_pods_ready`,
  `test_coredns_no_plugin_loop`. Live controller tail (.171) shows ZERO `No agent available`/503/
  `plugin/loop`/`Could not resolve` — konnectivity + CoreDNS healthy on a fresh-from-source boot.
  **All 8 issues backported and validated. Cluster is green from source.**

- 🔴 **REAL ISSUE #8 (missed by verify AGAIN!) — kube-state-metrics CrashLoopBackOff (:8080 bind conflict).**
  KSM (`registry.k8s.io/kube-state-metrics:v2.13.0`) in CrashLoopBackOff (Exit 1). Cited:
  `err="run server group error: listen tcp 0.0.0.0:8080: bind: address already in use"` (binds `[::]:8080`
  then fails `0.0.0.0:8080`). Deployed post-apply via `terraform_data.k0s_ksm_manifest` (inline heredoc
  in **main.tf** — owner = CORE). **Mechanism (LEAD confirmed live):** manifest sets `hostNetwork: true`
  and passes **NO container args** → KSM defaults to `--port=8080`, colliding with **kube-router holding
  the node `*:8080`** (`ss` shows kube-router pid; controller.yaml.tftpl:173 already notes ":8080 is taken
  by kube-router"). Declared containerPort/Service (8081/8082) are ignored w/o args.
  - **LEAD DECISION:** keep `hostNetwork` (spec uses it for a static node-IP scrape target; dropping →
    ephemeral pod IP the external hub can't scrape) + move KSM off 8080 to **8082/8083**, updating ALL
    refs in one pass (args + containerPort/hostPort + Service + the `:8081` comment) + add manifest
    content to `triggers_replace` so `just up` re-applies without a full recreate. 8082/8083 verified free.
  - **FIX-RUNNING-FIRST (core):** SSH controller-1, edit live `/var/lib/k0s/manifests/.../kube-state-metrics.yaml`,
    confirm KSM 1/1 Running, THEN backport into main.tf. **Test (vector):** assert KSM Ready (port 8082).
  - Redeploy: post-apply manifest → plain `just up` (re-triggers ksm_manifest), no full recreate needed.
  - ✅ **#8 FIXED (green from source):** KSM args `--port=8082/--telemetry-port=8083` (hostNetwork kept). `just up` re-applied; `just verify` **26 passed / 25 skipped / 0 failed**. Independent SSH: KSM 1/1 0-restarts 7m+, `:8082/metrics` serves 956 `kube_*`. New tests PASSED: `test_kube_state_metrics_ready`, `test_kube_state_metrics_serves_metrics`.

## Notes for LEAD
- ⚠️ Watcher gotcha: grepping ops's screen for `OPS-DONE` matches the literal marker in MY dispatch
  text visible in scrollback → false positive. Fix: exclude lines containing `print` or `<`
  placeholders; only trust a bare emitted marker line with concrete summary text.

## Notes / decisions
- Datastore **etcd** in BOTH modes (single-member @1 CP). k0s_version `v1.34.9+k0s.0`.
- NO `k0s install` / NO API-dependent step in cloud-init. k0sctl forms cluster post-apply.
- Vector: journald→socket/syslog + file(/var/log/pods)→VRL→OpenObserve http (drop_newest) + syslog copy. NO kubernetes_logs.
- Resolver warm-up gate UNCONDITIONAL; every net fetch bounded-retry (`for i in $(seq 1 5)`), never unbounded `until`.
- Heavy installs → post-boot systemd oneshot (`--no-block`), `package_upgrade: false` (300s launch window).
- Real k0sctl preflight: `command -v k0sctl` gate in `just up` recipe + fail-fast in terraform_data.

## KSM issue #8 — GREEN FROM SOURCE (ops, no live patches)
- Core moved KSM off :8080 → **:8082 (http-metrics) / :8083 (telemetry)**, kept hostNetwork, updated
  args + containerPort/hostPort + Service, and added the manifest to `triggers_replace` so it re-applies
  on `just up` (no recreate). `just check` 9/9 hermetic-green.
- Ops proof-from-source: `just up centralized_k0s` → `Apply complete! 1 added, 0 changed, 1 destroyed`
  (only `terraform_data.k0s_ksm_manifest` replaced → re-scp'd corrected manifest → k0s reconciled; NO
  VM churn). Rendered args `--port=8082 --telemetry-port=8083`; KSM deploy **1 avail / 1 desired**,
  container ports `8082 8083`, pod 1/1 Running.
- `just verify centralized_k0s` = **26 passed / 25 skipped / 0 failed** (ZERO live patches). New KSM
  gate PASSED: `test_kube_state_metrics_ready`, `test_kube_state_metrics_serves_metrics`. Prior
  functional gates still PASSED: konnectivity_agents_ready, metrics_api_serves_node_metrics,
  coredns_pods_ready, coredns_no_plugin_loop. Live tails (.171/.173) clean: 0 No-agent/503/plugin-loop/
  resolve/CNI signatures. **All 8 issues backported + validated green from source.**
