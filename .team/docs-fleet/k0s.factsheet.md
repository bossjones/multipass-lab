# Fact sheet: centralized_k0s

**One-liner:** A `just`-orchestrated, multi-node k0s Kubernetes cluster (k0sctl-formed, etcd-backed) that levels up the single-node k0s embedded in `centralized_monitoring`/`centralized_logging` into its own tunable-topology lab cluster, with an opt-in etcd-quorum HA mode behind an HAProxy edge.

**VMs:**
| VM role | Count | Sizing | Purpose |
|---|---|---|---|
| controller | 1 (default) / 3 (HA opt-in) | 3 vCPU / 3G / 20G | etcd + control plane + kubelet/cAdvisor via `--enable-worker` (control-plane taint kept); 3G sized for etcd OOM headroom |
| worker | 2 (default) / 3 (HA opt-in) | 2 vCPU / 4G / 30G | schedulable workload nodes |
| haproxy | 0 (default) / 1 (HA opt-in, i.e. `k0s_control_plane_count > 1`) | 1 vCPU / 1G / 10G | L4 passthrough edge for 6443/8132/9443 + native Prometheus exporter on `:8405` |

Default topology = 1 controller + 2 workers + no haproxy (**3 VMs total**, ~6 vCPU / 8–10G, single-member etcd) — sized to fit inside `just up-connected`. HA opt-in = 3 controllers + 3 workers + 1 haproxy (**7 VMs total**, ~13 vCPU / 19G, 3-member etcd quorum) — essentially the whole Mac; brought up stand-alone, not via `up-connected`.

**Existing docs (confirmed to exist on disk — do not list anything you have not verified):**
- `clusters/centralized_k0s/docs/feature-flags.md`
- Note explicitly: NO `README.md` or `USAGE.md` exists for this cluster yet.

**Specs:**
- `specs/centralized_k0s.md` — main design spec (status banner just fixed by this agent)
- `specs/centralized_k0s/build-plans/{core,k0sctl,node,vector-tests}.md` — build-plan shards

**web_urls / core dashboards (from outputs.tf):**
`core` is Netdata-only: one `http://<ip>:19999` per node (controller + worker), and only when `enable_netdata` is true (default on). There are no other "core" human dashboards for this cluster (no Grafana/Prometheus UI of its own — it's a compute cluster, not an observability stack). `all` (the `--full` set) adds node-exporter `:9100/metrics` on every node, plus HAProxy's native `:8405/metrics` when HA mode is on.

**Notes for the doc authors:**
- This is the **newest cluster on this branch** (`feature-re-arch`) — just went from spec DRAFT to fully implemented/verified in this session (`just check` 9/9, `just verify` 26 passed/25 skipped/0 failed, per `.team/centralized_k0s.board.md`).
- **No HA by default** — plain `just up centralized_k0s` gives the 3-VM single-controller shape; the HA opt-in (3 controllers + 3 workers + HAProxy) needs an explicit `k0s_control_plane_count = 3` / `worker_count = 3` override (e.g. a throwaway `ha.auto.tfvars`) and should be called out as stand-alone, not fleet-connected.
- CNI defaults to kube-router; Cilium is an opt-in, `just recreate`-class flag (`enable_cilium`) since CNI is immutable post-init.
- Log shipping (Vector → `centralized_logging` syslog + `centralized_monitoring` OpenObserve) is opt-in/empty by default, wired automatically by `just up-connected`.
- Cluster formation is via **k0sctl** (not Ansible yet) — the spec notes Ansible migration is a later iteration.
- The stable k0s API endpoint is `k0s-api.<domain>` (`spec.api.externalAddress`), resolving to the HAProxy IP in HA mode or controller-1 otherwise, so `k0s backup`/`restore` survives DHCP IP churn.
- 25 skips in the last `just verify` run are expected — HA-only roles/tests and unwired cross-cluster shipping, not failures.
