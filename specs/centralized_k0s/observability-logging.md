# Research shard — `observability-logging` for `clusters/centralized_k0s/`

> Scope: exporters + Netdata + **log shipping across all 6 nodes**, and the design to get
> **both host AND Kubernetes pod logs into `centralized_logging`**. One shard of a 5-agent fleet
> planning the new multi-node k0s cluster. Reference topology assumed below: **3 controllers +
> 3 workers** (the split is a design knob — `etcd`/system-component metrics imply HA controllers,
> workloads/pods run on workers). All findings are arm64-Mac / Multipass aware.

## Summary

- **`centralized_logging` ingests ONLY syslog RFC5424 over TCP `:514`** (syslog-ng `network()` →
  `/var/log/remote/$HOST/$PROGRAM.log`). It does **not** speak OTLP and does **not** run
  OpenObserve — that sink swap is explicitly *future work* in `specs/centralized_logging.md`. This
  is the pivot for the whole "all logs to the logging hub" question.
- **Host logs are already solved fleet-wide** by the shared syslog-ng client drop-in
  (`syslog-client.conf.tftpl`, var `log_shipping_target`). Its `system()` source reads **journald**,
  and **k0s runs every component as a journald-logged systemd service** (`k0scontroller` /
  `k0sworker`, with `component=<kubelet|etcd|...>` selectors) — so **k0s component logs + OS logs on
  all 6 nodes flow to `centralized_logging` with zero extra work** the moment `log_shipping_target`
  is set.
- **Pod/container logs are the gap.** Pod stdout/stderr is written by containerd/CRI to
  **`/var/log/pods/*/*/*.log`**, *not* journald — so syslog-ng's `system()` source never sees them.
  The only repo precedent (`otel/k0s-collector-config.yaml.tftpl`, `filelog/pods` → OpenObserve)
  ships them to the **monitoring** hub, not the logging hub.
- **Recommended design (the crux):** run **`otelcol-contrib`** on each **worker** with a
  `filelog/pods` receiver whose logs fan out to the **`syslog` exporter** (RFC5424 / TCP → the
  `centralized_logging` collector `:514`) — and, optionally, keep the existing `otlphttp` exporter
  to OpenObserve. This reuses the already-pinned `otelcol-contrib v0.117.0` binary, needs **no
  change to the logging hub** (syslog-ng already accepts RFC5424/TCP), and satisfies "all logs to
  `centralized_logging`". Details + the exact config in [§ Log shipping](#log-shipping-to-centralized_logging-host--pods).
- **Netdata**: the shared snippet (`install-netdata.sh.tftpl`) applies **unchanged** to all 6 nodes;
  `enable_ebpf` stays **OFF** on arm64 (unproven on arm64 stable — the fleet default already off).
- **Exporters**: node-level exporters (`node_exporter :9100`, `systemd_exporter :9558`,
  `process-exporter :9256`, `netdata :19999`) go on **all 6 nodes**; **kubelet/cAdvisor** on
  **workers** (where kubelet actually runs); **etcd metrics + k0s system-component metrics** on
  **controllers**; **kube-state-metrics** is **cluster-wide → exactly one Deployment**.

## Exporters per role

Ports/versions/flags carried over from `centralized_monitoring/cloud-init/k0s-client.yaml.tftpl`
(the single-node precedent) and split by role for the multi-node cluster.

| Exporter | Port | Controllers (×3) | Workers (×3) | Notes / source of truth |
|---|---|:---:|:---:|---|
| **node_exporter** | `:9100` | ✅ | ✅ | OS host + systemd metrics; `--collector.systemd`. Pin **v1.8.2**. All nodes are Linux hosts. |
| **systemd_exporter** | `:9558` | ✅ | ✅ | Per-unit health; unit-include regex already matches `k0s.*`, `kube.*`, `containerd`, `netdata`. **v0.7.0**. |
| **process-exporter** | `:9256` | ✅ | ✅ | Curated groups (`k0s`, `kubelet`, `etcd`, container-runtime). **v0.8.7**. |
| **Netdata** | `:19999` | ✅ | ✅ | Shared snippet, `average` Prometheus endpoint. See [§ Netdata](#netdata). |
| **kubelet (read-only)** | `:10255` | ⚠️ only if `--enable-worker` | ✅ | k0s controllers are **workload-isolated by default → no kubelet**. Enable RO port via `--kubelet-extra-args="--read-only-port=10255"` (as in the single-node precedent). Serves `/metrics`, `/metrics/cadvisor`, `/stats`. |
| **cAdvisor** (standalone) | `:8089` | ❌ | ✅ | Container metrics; `:8080` is taken by k0s kube-router, hence `:8089`. **v0.49.1**. Only where pods run. (Redundant with kubelet's `/metrics/cadvisor` — pick one; standalone gives richer per-container detail.) |
| **kube-state-metrics** | `:8081` | ➖ one Deployment | ➖ (schedules on a worker) | **Cluster-wide singleton** — `replicas: 1`, `hostNetwork: true`, `registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.13.0`, `--kubeconfig=/etc/ksm/kubeconfig`. Scrape it at `<node-it-lands-on>:8081`. Not per-node. |
| **etcd metrics** | `:2381` | ✅ | ❌ | Embedded etcd exposes Prometheus metrics on its **`--listen-metrics-urls` (`:2381`, HTTP, no client cert)**; client/peer traffic is `:2379`/`:2380`. Controllers only. Only relevant for **etcd-backed** k0s (default); if kine/sqlite is used there's no etcd. |
| **k0s system-component metrics** (via pushgateway) | `:9091` | ✅ (opt-in) | ❌ | See [§ k0s native metrics](#k0s-native-system-component-metrics). One `k0s-pushgateway` in `k0s-system`. |

**Rule of thumb:** *host* exporters everywhere; *kubelet/cAdvisor* follow the kubelet (workers);
*etcd + control-plane* metrics on controllers; *kube-state-metrics* exactly once.

### k0s native system-component metrics

Confirmed against <https://docs.k0sproject.io/stable/system-monitoring/>:

- **Opt-in at install:** `k0s install controller --enable-metrics-scraper`.
- It deploys a **`k0s-pushgateway` Deployment in the `k0s-system` namespace**, listening on
  **`:9091/TCP`**, with a **2-minute default TTL** for metric freshness.
- Components scraped through it: **`kube-scheduler`, `kube-controller-manager`, `etcd`, `kine`**.
- **`kube-apiserver` metrics are deliberately NOT scraped** here — they're reachable via the
  in-cluster `kubernetes` endpoint (`https://<api>:6443/metrics`, needs a bearer token).
- **Controller-only** (that's where the control plane runs; controllers are workload-isolated).
- Prometheus-Operator users target it with a `ServiceMonitor` matching labels
  `app: k0s-observability`, `component: pushgateway`, `k0s.k0sproject.io/stack: metrics`. For this
  lab's **pull-from-external-Prometheus** model, just add a static scrape of the pushgateway's
  hostNetwork/NodePort address `:9091` (see [§ Prometheus scrape](#prometheus-scrape-monitoring-hub)).

## Netdata

- **Shared snippet applies unchanged.** `clusters/_shared/cloud-init/install-netdata.sh.tftpl` is
  fleet-generic: idempotent kickstart install (no `--claim-*` → local-only, no Netdata Cloud),
  max-stats `netdata.conf`, host labels, docker-group add, `:19999` Prometheus endpoint
  (`/api/v1/allmetrics?format=prometheus`, `average` source). Render it per-node with
  `host_labels = { cluster = var.name_prefix, role = "controller"|"worker", environment = "lab" }`
  and `enable_ebpf = var.enable_netdata_ebpf`. All 6 nodes, controllers and workers alike — nothing
  k0s-specific blocks it.
- **eBPF stays OFF on arm64.** `enable_netdata_ebpf` default **false** (per `specs/shared-netdata.md`,
  the eBPF collector is the heaviest and its arm64-stable availability is uncertain). Verify on a
  node before flipping it on: `sudo netdata -W buildinfo | grep -i ebpf`.
- **Port hygiene:** the snippet disables Netdata's internal `statsd`/`otel` plugins, so `:8125`/OTLP
  don't clash with the otelcol log-shipper added below. No conflict with `:19999`.
- **Docker SD** auto-configures per-container collectors once `netdata` is in the `docker` group —
  useful on workers running containerd (note: containerd, not dockerd, so the docker-socket SD may
  be a no-op here; Netdata's cgroup collector still picks up container cgroups regardless).

## Log shipping to `centralized_logging` (host + pods)

### What `centralized_logging` actually ingests (investigated)

From `specs/centralized_logging.md` + `syslog-client.conf.tftpl`:

- **Protocol:** syslog-ng `network(transport(tcp) port(514) flags(syslog-protocol))` — i.e.
  **RFC5424 over TCP `:514`**, written to `/var/log/remote/$HOST/$PROGRAM.log`.
- **No OTLP, no OpenObserve** on the logging hub (a commented VictoriaLogs/OpenObserve sink is
  *future work*, not built). So anything shipped to the logging hub must be **syslog RFC5424/TCP**.
- The shared **syslog-ng client drop-in** already exists and ships `s_src` = **journald +
  syslog-ng internal()** to `<central_ip>:<syslog_port>` with a reliable disk buffer, gated on
  `log_shipping_target`.

### Host + k0s-component logs — already covered ✅

k0s runs its components as **systemd services logging to journald** (confirmed via
<https://docs.k0sproject.io/stable/troubleshooting/logs/>: `journalctl -u k0scontroller` /
`journalctl -u k0sworker`, filtered by `component=kubelet|etcd|kube-scheduler|...`). syslog-ng's
`system()` source reads journald, so **setting `log_shipping_target` on all 6 nodes ships OS logs +
every k0s control-plane/worker component log to `centralized_logging` with no extra config.**
containerd's own daemon logs also go to journald and ride along.

### Pod/container logs — the gap and the recommended bridge ⭐

**Problem:** pod stdout/stderr is written by containerd/CRI to **`/var/log/pods/<ns>_<pod>_<uid>/<container>/*.log`** (symlinked from `/var/log/containers/`) — **not journald**. So `system()` never
sees them, and the only repo precedent ships them to **OpenObserve on the monitoring hub**, not the
logging hub.

**Recommended design — otelcol-contrib `filelog/pods` → `syslog` exporter → `centralized_logging:514`.**
Run `otelcol-contrib` (the already-pinned **v0.117.0** binary, as root, on each **worker** where
pods actually run) reading `/var/log/pods/*/*/*.log` and exporting **RFC5424 syslog over TCP** to
the logging hub. syslog-ng already accepts exactly that framing — **zero change to the hub.**

```yaml
# /etc/otelcol/pods-to-logging.yaml  (workers only; runs as root to read /var/log/pods)
receivers:
  filelog/pods:
    include: [ /var/log/pods/*/*/*.log ]
    include_file_path: true
    start_at: beginning
    storage: file_storage
    operators:
      - type: container          # auto-detects CRI/containerd format; adds k8s.namespace/pod/container attrs

extensions:
  file_storage:
    directory: /var/lib/otelcol-contrib/storage   # dir must pre-exist; chown to the unit's user

processors:
  batch: {}
  # Give the syslog exporter the fields it needs; without these it emits empty APP-NAME/HOSTNAME.
  transform:
    log_statements:
      - context: log
        statements:
          - set(attributes["appname"], attributes["k8s.pod.name"])
          - set(attributes["hostname"], resource.attributes["k8s.node.name"])
          - set(attributes["message"], body)

exporters:
  syslog:
    network: tcp
    endpoint: ${logging_hub_ip}       # centralized_logging central VM
    port: 514
    protocol: rfc5424                  # matches syslog-ng flags(syslog-protocol)
    # tls: { insecure: true }  # plaintext to match the current :514 listener

service:
  extensions: [file_storage]
  pipelines:
    logs/pods:
      receivers: [filelog/pods]
      processors: [batch, transform]
      exporters: [syslog]
      # add otlphttp/pods here too if you also want them in OpenObserve (fan-out)
```

Why this over the alternatives:

- **vs. Fluent Bit** (`tail` → `syslog` output): also works, but adds a *second* log agent + package;
  otelcol-contrib is already in the fleet and pinned. Prefer one binary.
- **vs. teaching `centralized_logging` to speak OTLP** (add OpenObserve/an otelcol receiver to the
  hub): heavier — changes the hub's identity and its "syslog-ng only" MVP. Keep the hub dumb; adapt
  at the edge. (If structured k8s metadata *must* be preserved losslessly, this is the fallback —
  syslog flattens structure; see risks.)
- **Endpoint/protocol, concretely:** **TCP `:514`, RFC5424** to the `centralized_logging`-central
  VM IP (discovered the same way `log_shipping_target` is — via the hub's `tofu output hosts`).

**Net wiring for "all logs → `centralized_logging`":** set `log_shipping_target` on **all 6 nodes**
(host+journald+k0s components, via the existing syslog-ng drop-in) **and** run the otelcol
`filelog/pods → syslog` bridge on the **3 workers** (pod logs). Controllers need only the syslog-ng
drop-in (they run no workloads).

## Prometheus scrape (monitoring hub)

Noted for completeness — emphasis of this shard is logs. The monitoring hub pulls via the
repo's `extra_scrape_targets` pattern (list of `{job, ip, port}` templated into `prometheus.yml`,
hot-pushed by `up-connected`/`refresh-cross-cluster` with no VM recreate). Targets to register:

- **Per node (×6):** `node_exporter :9100`, `systemd_exporter :9558`, `process-exporter :9256`.
- **Netdata (×6):** `:19999` — note this needs `metrics_path: /api/v1/allmetrics` + `params:
  {format: [prometheus]}`, which the plain `extra_scrape_targets` loop can't express; use the
  dedicated `netdata_scrape_targets` mechanism from `specs/shared-netdata.md` (folds into
  `job="netdata"`).
- **Workers (×3):** kubelet RO `:10255` (`/metrics`, `/metrics/cadvisor`), cAdvisor `:8089`.
- **Cluster-wide (×1):** kube-state-metrics `:8081`.
- **Controllers (×3):** etcd `:2381`; k0s system-component metrics via pushgateway `:9091`
  (only if `--enable-metrics-scraper`).

## Open risks / adversarial-bait

1. **The whole premise:** "all logs → `centralized_logging`" is only *partly* pre-solved. Host +
   k0s-component logs are trivial (journald→syslog-ng), but **pod logs need the new otelcol→syslog
   bridge**. Don't let a reviewer assume the existing syslog-ng drop-in covers pods — **it does
   not** (pods bypass journald).
2. **otelcol `syslog` exporter field mapping.** Without the `transform` step, the exporter emits
   RFC5424 with empty `APP-NAME`/`HOSTNAME`/structured-data and the k8s metadata (namespace/pod/
   container from the `container` operator) is **lost** — syslog is a flat line format. If lossless
   k8s metadata matters, this bridge is the *wrong* tool; ship pods to OpenObserve (structured) and
   only mirror to the logging hub for archival. Call this out explicitly.
3. **`/var/log/pods` symlinks + the `container` operator** must read the real files; run otelcol as
   **root** (the precedent does). If it runs as the `.deb`'s `otelcol-contrib` user it can't read
   `/var/log/pods` — permission-denied, silent empty stream. (Compare the host-only shared
   `otel-agent-config` which chowns the storage dir to the unit user; the pods path needs root.)
4. **Duplicate log volume / cost.** If pods fan out to *both* OpenObserve and syslog-ng, and hosts
   already ship journald, you can double-count. Also the syslog-ng disk-buffer on the hub was sized
   for host syslog, not full pod-log firehose — `disk-buf-size(512MiB)` per client may be tight
   under chatty pods. Note back-pressure (`flags(flow-control)`) can stall the shipper.
5. **etcd metrics only exist if k0s uses etcd.** A kine/SQLite or external-SQL k0s has **no `:2381`**
   — the exporters table's etcd row is conditional on the datastore choice.
6. **Controllers vs kubelet.** k0s controllers are workload-isolated by default → **no kubelet, no
   cAdvisor, no `/var/log/pods`** there. Putting kubelet/cAdvisor/pod-log shipping on controllers is
   wasted (or requires `--enable-worker`, which changes the isolation model). Get the topology
   decision (dedicated controllers vs controller+worker) locked before wiring exporters.
7. **k0s-pushgateway TTL (2 min).** Prometheus scrape interval must be < 2 min or metrics go stale/
   absent — an easy silent gap.
8. **Multipass launch window (300s) vs multi-node boot.** Six VMs each pulling k0s + exporters +
   Netdata + otelcol risks the documented DNS-warm-up race and the 300s `multipass launch` timeout
   (see the repo's "silent wait loop" gotcha). Every network install needs the resolver-ready gate +
   retry idiom already used in `k0s-client.yaml.tftpl` and `install-netdata.sh.tftpl`.
9. **`:514` is privileged.** syslog-ng on the hub binds `:514` fine, but confirm the otelcol syslog
   exporter can *connect* (egress) — no privilege needed to connect, only to bind. Non-issue, but
   reviewers conflate the two.

## Sources

- Repo: `clusters/_shared/cloud-init/install-netdata.sh.tftpl`, `syslog-client.conf.tftpl`,
  `otel-agent-config.yaml.tftpl`; `clusters/centralized_monitoring/cloud-init/k0s-client.yaml.tftpl`
  and `cloud-init/otel/k0s-collector-config.yaml.tftpl`; `specs/centralized_logging.md`,
  `specs/shared-netdata.md`.
- k0s system monitoring (metrics-scraper, k0s-pushgateway `:9091`, 2-min TTL, controller-only,
  components scraped): <https://docs.k0sproject.io/stable/system-monitoring/>
- k0s logging (components → journald as `k0scontroller`/`k0sworker` with `component=` selectors;
  OpenRC → `/var/log/k0s*.log`): <https://docs.k0sproject.io/stable/troubleshooting/logs/>
- OpenTelemetry Collector Contrib `syslogexporter` (RFC5424/RFC3164 over TCP/UDP/TLS) and `filelog`
  receiver `container` operator — the mechanism for the pod-log bridge.
