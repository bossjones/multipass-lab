# Feature Flags

Every tunable is a variable defined in [`variables.tf`](../variables.tf). Unlike the
`centralized_*` observability clusters (where each `enable_*` gates a single exporter), the flags
here fall into three groups: **topology** (`count`-driven, decides HA + whether HAProxy exists),
**opt-in features** (CNI, Netdata), and **cross-cluster wiring** (DNS / trust / NTP / log shipping —
all empty by default so a plain `just up` stays turnkey + isolated). See
[`specs/centralized_k0s.md`](../../../specs/centralized_k0s.md) for the authoritative design.

- [The full flag matrix](#the-full-flag-matrix)
- [Topology & HA](#topology--ha)
- [CNI (Cilium opt-in)](#cni-cilium-opt-in)
- [Log shipping (Vector)](#log-shipping-vector)
- [Cross-cluster DNS / trust / NTP](#cross-cluster-dns--trust--ntp)
- [Changing the footprint](#changing-the-footprint)

## The full flag matrix

| Variable | Default | Kind | What it does |
|----------|:-------:|------|--------------|
| `k0s_control_plane_count` | `1` | topology | Number of controller VMs. `1` = etcd single-member, **no HAProxy**, direct-to-controller-1. `3` = the HA opt-in (3-member etcd quorum behind an HAProxy edge). **>1 also creates the HAProxy VM.** |
| `worker_count` | `2` | topology | Number of worker VMs. Default `2` (fits `up-connected`); HA uses `3`. |
| `enable_cilium` | ❌ | feature | Opt-in Cilium CNI (kube-router is the v1 default). CNI is immutable post-init → a `just recreate`-class flag. |
| `enable_netdata` | ✅ | feature | Netdata real-time agent (`:19999`) on every node — per-second host/container/systemd metrics + a built-in dashboard. Standalone (no Netdata Cloud), telemetry off. |
| `enable_netdata_ebpf` | ❌ | feature | Netdata's eBPF collector (heaviest; arm64-stable availability varies). Base install still runs all standard collectors. |
| `log_shipping_target` | `""` | cross-cluster | `host:port` of the `centralized_logging` syslog-ng collector (TCP/514). Non-empty → Vector ships host + k0s-component logs there as RFC5424 syslog, plus a flat archival copy of pod logs. |
| `openobserve_endpoint` | `""` | cross-cluster | `host:port` of `centralized_monitoring`'s OpenObserve. Non-empty → Vector ships structured pod logs to its `/api/<org>/<stream>/_json` endpoint. |
| `openobserve_org` | `""` | cross-cluster | OpenObserve organization the pod-log `_json` ingest targets. |
| `openobserve_stream` | `""` | cross-cluster | Stream name in the `/api/<org>/<stream>/_json` ingest URL for pod logs. **New value** in the cross-cluster var contract (the `_json` URL names the stream). |
| `openobserve_password` | `""` | cross-cluster | Basic-auth password for the Vector `http` sink (must match the monitoring hub's OpenObserve root user). |
| `dns_server` | `""` | cross-cluster | IP/`host[:port]` of the `centralized_dns` AdGuard resolver. Non-empty → every VM points systemd-resolved at it at first boot. |
| `internal_ca_cert` | `""` | cross-cluster | PEM of the internal root CA. Non-empty → each VM drops it into the OS trust store + runs `update-ca-certificates` at first boot. |
| `ntp_server` | `""` | cross-cluster | IP/`host[:port]` of an internal NTP source. Non-empty → every VM points systemd-timesyncd at it. |
| `k0s_version` | `v1.34.9+k0s.0` | pin | k0s release (Kubernetes 1.34.9 / etcd 3.6.12). Threaded into `K0S_VERSION` (cloud-init) + `k0sctl.yaml`. |
| `ksm_version` | `v2.13.0` | pin | kube-state-metrics image, applied post-apply via the k0s manifest deployer. |

All cross-cluster wiring vars default **empty**, so a plain `just up centralized_k0s` is turnkey and
isolated; `just up-connected` discovers the live hub IPs and wires them fleet-wide. The
`enabled_features` output (`{ha, cilium, netdata}`) and `cross_cluster_enabled` drive the live suite
to **skip** (not fail) checks for a feature that's off — see [Log shipping](#log-shipping-vector).

## Topology & HA

`k0s_control_plane_count` is the master switch. The control-plane count decides HA **and** whether
the HAProxy VM exists (`local.ha_mode = k0s_control_plane_count > 1`):

| Mode | controllers | workers | HAProxy | VMs | ~vCPU / RAM | etcd |
|---|:---:|:---:|:---:|:---:|---|---|
| **Default** (`up-connected`-fit) | 1 | 2 | ❌ (direct to controller-1) | 3 | ~6 / 8–10 G | single-member |
| **HA opt-in** | 3 | 3 | ✅ | 7 | ~13 / 19 G | 3-member quorum |

- **etcd is unconditional in both modes** (single-member when 1 controller) — keeps the 1↔3 render
  and the hermetic assertions coherent.
- The **HA opt-in is essentially the whole Mac** (~13 vCPU / 19 G) — bring it up **stand-alone**,
  not via `up-connected` (which uses the 3-VM default). Drop a throwaway `ha.auto.tfvars` with
  `k0s_control_plane_count = 3` / `worker_count = 3` (it outranks `terraform.tfvars`).
- **HA honesty:** this is **etcd-quorum HA behind a SPOF edge**, not full HA. The single HAProxy is a
  deliberate lab SPOF; the failover drill validates etcd quorum (2/3) + HAProxy backend
  health-checking. Full CPLB+NLLB HA is the Proxmox target. HAProxy exposes its **native Prometheus
  exporter** on `:8405`, scraped by the monitoring hub.
- The stable API endpoint is `k0s-api.<domain>` (`spec.api.externalAddress`) → the HAProxy IP in HA
  mode / controller-1 in single mode, so `k0s backup`/`restore` survives DHCP IP churn.

## CNI (Cilium opt-in)

`enable_cilium` (default off) swaps the v1 default **kube-router** for **Cilium** (eBPF,
kube-proxy-replacement). CNI is **immutable after cluster init**, so flipping this is a
`just recreate`-class change, not a live `just up`. eBPF on Multipass arm64 is feasible but unproven
— this is an iteration-2 flag.

## Log shipping (Vector)

**One Vector agent per node** ([`cloud-init/vector/vector.toml.tftpl`](../cloud-init/vector/vector.toml.tftpl)),
with two log paths and **no Kubernetes API dependency**:

1. **Host + k0s-component logs** — a `journald` source → a **`socket` sink with
   `encoding.codec = "syslog"`** (RFC5424 over TCP) → `centralized_logging:514`. Vector has no
   dedicated "syslog sink"; it's the socket sink + the syslog codec. HOSTNAME/APP-NAME are populated
   in a VRL transform so the hub's `keep-hostname(yes)` folders each node correctly.
2. **Pod logs** — a **`file` source** over `/var/log/pods/*/*/*.log` (present on all nodes now that
   controllers run kubelet via `--enable-worker`) → a **VRL** transform that path-parses
   `/var/log/pods/<ns>_<pod>_<uid>/<container>/` into **namespace / pod / container** (no K8s API, no
   kubeconfig, no boot-order fragility — the `kubernetes_logs` source was rejected precisely because
   it needs API access Vector lacks at boot). Two sinks:
   - **(a) OpenObserve** `http` sink → `/api/<org>/<stream>/_json` with basic auth,
     `encoding.codec = json`, and **`buffer.when_full = "drop_newest"`** so a down hub can't
     back-pressure and stall the archival path.
   - **(b)** a flat **socket/syslog** archival copy to `centralized_logging` (may split multiline
     pod logs — archival only; the OpenObserve copy stays intact).

The shipping sinks are **gated on their target vars being non-empty**: with `log_shipping_target` and
`openobserve_endpoint` empty (the default), Vector collects locally and ships nowhere. `up-connected`
wires `log_shipping_target` (→ logging syslog) and `openobserve_endpoint` from live hub IPs; the
`openobserve_org` / `openobserve_stream` / `openobserve_password` complete the `_json` URL + auth.

> **Enrichment is the real proof.** The live suite
> ([`tests/testinfra/test_vector.py`](../tests/testinfra/test_vector.py)) asserts an actual
> OpenObserve record whose `namespace`/`pod`/`container` are **populated** (the VRL path-parse
> worked), not merely that "a record appears" — plus a syslog line in the logging hub's
> `/var/log/remote/`. It skips cleanly when shipping is unwired (`cross_cluster_enabled == false`).

## Cross-cluster DNS / trust / NTP

`dns_server`, `internal_ca_cert`, and `ntp_server` are the standard fleet opt-ins (empty default,
gated `write_files`/drop-in idiom shared with every other cluster). Non-empty values point
systemd-resolved / the OS trust store / systemd-timesyncd at the fleet hubs at first boot. A baseline
UTC time-sync is applied unconditionally regardless of `ntp_server`. The **resolver warm-up gate in
cloud-init is unconditional** (not gated on `dns_server`) — it's the first-boot boot-race guard that
keeps every network fetch (`get.k0s.sh`, oh-my-zsh, Vector, tool releases) from failing silently on a
DNS miss.

## Changing the footprint

Cross-cluster opt-ins auto-load from `.cross-cluster.auto.tfvars.json` (written by `up-connected`).
To change a default by hand, set the variable — via `-var` or a throwaway `*.auto.tfvars`:

```sh
# HA opt-in (stand-alone — ~13 vCPU / 19 G): drop clusters/centralized_k0s/ha.auto.tfvars with
#   k0s_control_plane_count = 3
#   worker_count            = 3
K0S_HA=1 just up centralized_k0s

# swap to Cilium (recreate — CNI is immutable post-init)
tofu -chdir=clusters/centralized_k0s apply -var enable_cilium=true   # then: just recreate

# turn Netdata off fleet-wide on this cluster
tofu -chdir=clusters/centralized_k0s apply -var enable_netdata=false
```

> Because the provider keys the VM on the cloud-init **file path** (not content), changing a flag
> that only alters rendered cloud-init re-renders `.rendered/*.yaml` but does **not** recreate a
> running VM. To apply cloud-init / `k0sctl.yaml` / `vector.toml` edits, use
> **`just recreate centralized_k0s`**, never a plain `just up`. See
> [`specs/centralized_k0s.md`](../../../specs/centralized_k0s.md) § "Applying cloud-init / config
> changes".
