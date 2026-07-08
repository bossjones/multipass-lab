# centralized_k0s — TEAM BOARD

**FSM:** `DONE` 🟢  ·  **target:** default 1 CP + 2 workers  ·  **GREEN FROM SOURCE (with #8 gate)**

`just check` ✅ 9/9 · `just up` re-apply ✅ · `just verify` ✅ **26 passed / 25 skipped / 0 failed** — NO live patches.

| agent | emoji | state | last log |
|-------|-------|-------|----------|
| 👑 lead   | 🟢 | DONE | verify 26/0 green from source; #6+#7+#8 fixed & test-gated; fsm=DONE |
| 🏗 core   | 🟢 | done | #8 KSM off 8080→8082/8083 (hostNetwork kept), all refs + triggers; live 1/1 + check 9/9 |
| 📦 node   | 🟢 | done | /etc/hosts k0s-api fallback + ungated vector install + etcdctl completion |
| ⚙️ k0sctl | 🟢 | done | #6 externalAddress→ctl IP + #7 kubelet resolvConf→/run/systemd/resolve/resolv.conf |
| 📊 vector | 🟢 | done | #8 KSM-Ready assertion (port 8082) + konnectivity/CoreDNS tests; hermetic green |
| 🚀 ops    | 🟢 | done | `just up` re-apply + `just verify` 26/0 green from source; tails live throughout |

Legend: 🔵 working · 🟢 done · 🔴 error · ⚪ queued

## Final verify (green from source, no live patches)
- 3/3 nodes Ready (k0s v1.34.9+k0s); default 1 CP + 2 workers, no HAProxy.
- NEW functional assertions all **PASSED**: `test_konnectivity_agents_ready`,
  `test_metrics_api_serves_node_metrics`, `test_coredns_pods_ready`, `test_coredns_no_plugin_loop`.
- 25 skips = expected HA-only roles (controller-2/3, worker-3), HA tests, unwired cross-cluster shipping.
- LEAD independent SSH check: konnectivity 3× 1/1 (0 restarts), `kubectl top nodes` returns metrics,
  CoreDNS `plugin/loop` count 0.

## Source fixes shipped (all backported + verified)
- CORE main.tf: drop `--disable-telemetry`; `k0s_api_ip`→worker render; `k0s_api_ipv4`→k0sctl render.
- NODE controller/worker.yaml.tftpl: `/etc/hosts` k0s-api fallback; ungate vector install; etcdctl `_etcd`→`_etcdctl`.
- k0sctl.yaml.tftpl: (#6) `externalAddress`→controller IP (single-CP); (#7) kubelet `--resolv-conf=/run/systemd/resolve/resolv.conf`.
- VECTOR vector.toml: blackhole fallback sink + escape `${}` comments + fallible VRL `.appname, err=`; +4 functional tests.
