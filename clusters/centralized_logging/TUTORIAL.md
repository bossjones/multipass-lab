# 📘 Tutorial: Standing Up the Metrics/Exporter Layer

A hands-on walkthrough for bringing up the **centralized_logging** Multipass cluster and proving
every Prometheus exporter on it actually serves `/metrics` — so the layer is ready for a future
Prometheus to scrape. You already have the cluster code; this tutorial is about *running* and
*verifying* it, not building it from scratch.

> 📐 For the full design rationale (why these exporters, why this architecture), read
> [`../../specs/centralized_logging_metrics.md`](../../specs/centralized_logging_metrics.md).
> For general cluster usage (lifecycle, log shipping, troubleshooting beyond metrics), see
> [`USAGE.md`](USAGE.md) and [`README.md`](README.md).

---

## What you'll learn

By the end of this tutorial you will be able to:

- Bring up all three `centralized_logging` VMs and wait for cloud-init to finish.
- Verify every enabled exporter's `/metrics` endpoint is reachable, grouped by which VM(s) it
  lives on.
- Confirm the syslog-ng-via-textfile-collector metrics pipeline is producing data.
- Prove exporters are bound to `0.0.0.0` (not `127.0.0.1`) by reaching one VM's exporter from
  *another* VM — the precondition for a future cross-cluster scrape.
- Diagnose the handful of "this looks broken but isn't" situations (journald-exporter off by
  design, cloud-init still settling, the local `multipass exec` routing quirk).

## What you'll build / verify

```
        ┌──────────────────────────── future ────────────────────────────┐
        │            centralized_monitoring Prometheus (not built yet)    │
        └───────▲───────────────────▲────────────────────────▲───────────┘
                │ pull              │ pull                    │ pull
   central:9100/9558/9256/9943   docker:9100/9558/9256/8089/8082   k0s:9100/9558/9256/8089/10249/10255/8081
        │                            │                          │
   ┌────┴────┐                  ┌────┴────┐                ┌────┴────┐
   │ central │                  │ docker  │                │  k0s    │
   │syslog-ng│                  │ stack + │                │ k0s +   │
   │ server  │                  │ shipper │                │ shipper │
   └─────────┘                  └─────────┘                └─────────┘
```

This tutorial does **not** wire up that future Prometheus — it only proves the targets exist and
answer. The architecture principle here is **"exporters present, pull deferred."** Every exporter
is installed and bound to `0.0.0.0`, but nothing scrapes them yet; a separate
`centralized_monitoring` cluster will do that later. Notably, the `docker` VM's own on-box
Prometheus (`/opt/stack/prometheus.yml`) is **intentionally not** pointed at any of these
exporters — don't go looking for them there.

## Prerequisites

- The `centralized_logging` cluster code already checked out (you're reading this from inside it).
- `multipass`, `tofu` (OpenTofu ≥ 1.7), `just`, and `uv` installed — see
  [USAGE.md §2](USAGE.md#2-prerequisites) if any are missing.
- An SSH keypair at `~/.ssh/id_ed25519[.pub]` (cloud-init injects the public half into each VM).
- ~15-20 minutes: most of that is VM boot + cloud-init (exporter binary downloads), not typing.

## Time estimate

15-20 minutes, mostly waiting on `just up`.

---

## 1. Bring the cluster up

Run everything from the repo root: `/Users/bossjones/dev/bossjones/multipass-lab`.

First, the hermetic check — no VMs touched, just `tofu fmt` + `validate` + the mocked-provider
`tofu test`:

```sh
just check centralized_logging
```

Then launch all three VMs in a single `tofu apply`. This blocks until cloud-init has finished on
**every** VM — including all the exporter binary downloads and systemd unit installs — so when it
returns, the cluster is genuinely ready:

```sh
just up centralized_logging
```

> ⏳ This is the slow step. Cloud-init is installing syslog-ng, k0s, Docker, *and* five-to-nine
> exporter binaries per VM (arm64 builds). Give it the full 600s budget if your network is slow.

Sanity-check that all three VMs are running:

```sh
just status
```

Expected output (abridged):

```
Name                          State    IPv4
centralized-logging-central   Running  192.168.64.x
centralized-logging-k0s       Running  192.168.64.y
centralized-logging-docker    Running  192.168.64.z
```

Recall the three VMs and their roles:

| VM | Role |
|----|------|
| `centralized-logging-central` | syslog-ng **server** — log sink at `/var/log/remote` |
| `centralized-logging-k0s` | single-node **k0s** + syslog-ng client |
| `centralized-logging-docker` | **Docker Compose** stack (Traefik/Heimdall/Grafana/Prometheus/Alertmanager) + syslog-ng client |

All three are **Ubuntu 24.04 on arm64 (aarch64)** — that matters later when journald-exporter
comes up.

---

## 2. Run the live metrics test suite

Before poking at endpoints by hand, run the automated check — it's exactly what you're about to
do manually, just faster and parametrized over whichever exporters are actually enabled:

```sh
just verify centralized_logging
```

This runs `pytest` + `testinfra` over SSH, including `tests/testinfra/test_metrics.py`, which:

- curls every enabled exporter's `/metrics` on the right VM(s) and asserts HTTP 200,
- confirms the syslog-ng textfile `.prom` file exists and contains `syslogng_` series,
- confirms systemd_exporter's output mentions the `syslog-ng.service` unit,
- confirms the k0s VM can reach central's node_exporter across the network (the `0.0.0.0`-bind
  proof).

✅ **Checkpoint:** if `just verify` passes, you already have everything this tutorial proves —
the rest of the sections walk through the *same* checks by hand so you understand what's actually
running and can debug it later.

---

## 3. Discover what's enabled

Two OpenTofu outputs exist specifically for this: a sorted list of active flags, and a
per-role/per-exporter port map.

```sh
tofu -chdir=clusters/centralized_logging output -json enabled_exporters
```

```json
[
  "cadvisor",
  "filestat",
  "kube",
  "kube_state",
  "node",
  "process",
  "systemd",
  "traefik"
]
```

> Note `journald` is **absent** from this list by default — see [§8](#8-troubleshooting).

```sh
tofu -chdir=clusters/centralized_logging output -json metrics_targets
```

```json
{
  "central": { "ip": "192.168.64.x", "exporters": {"node":9100,"systemd":9558,"journald":12345,"process":9256,"filestat":9943} },
  "docker":  { "ip": "192.168.64.y", "exporters": {"node":9100,"systemd":9558,"journald":12345,"process":9256,"cadvisor":8089,"traefik":8082} },
  "k0s":     { "ip": "192.168.64.z", "exporters": {"node":9100,"systemd":9558,"journald":12345,"process":9256,"cadvisor":8089,"kube_proxy":10249,"kubelet":10255,"kube_state":8081} }
}
```

Keep this output handy — you'll use the IPs in [§7](#7-cross-vm-reachability-the-000-bind-proof)
and again when you wire up the future monitoring cluster.

---

## 4. Verify the core exporters (all three VMs)

These five run on **every** VM. SSH onto each in turn:

```sh
just ssh centralized_logging central   # then k0s, then docker
```

> ⚠️ If `just ssh` (or `multipass exec`/`multipass shell`) fails with **"No route to host"**, see
> [§8 Troubleshooting](#8-troubleshooting) for the direct-SSH workaround — it's a known quirk on
> this host, not a sign the cluster is broken.

Once you're on a VM, check the listeners and curl each one:

```sh
sudo ss -tlnp | grep -E ':(9100|9558|12345|9256)\b'
```

**node_exporter** (`:9100`, flag `enable_node_exporter`, default on) — also serves the syslog-ng
textfile metrics (more on that in [§6](#6-syslog-ng-metrics-the-textfile-collector)):

```sh
curl -fsS http://localhost:9100/metrics | head
```

```
# HELP go_gc_duration_seconds A summary of the pause duration of garbage collection cycles.
# TYPE go_gc_duration_seconds summary
go_gc_duration_seconds{quantile="0"} 0
...
```

**systemd_exporter** (`:9558`, flag `enable_systemd_exporter`, default on) — confirm it actually
reports on the `syslog-ng.service` unit, since that's the whole point of having it on this
cluster:

```sh
curl -fsS http://localhost:9558/metrics | grep 'syslog-ng.service'
```

```
node_systemd_unit_state{name="syslog-ng.service",state="active",type="simple"} 1
```

**process-exporter** (`:9256`, flag `enable_process_exporter`, default on):

```sh
curl -fsS http://localhost:9256/metrics | head
```

**journald-exporter** (`:12345`, flag `enable_journald_exporter`, **default off**) — do not expect
this one. See [§8](#8-troubleshooting) for why.

✅ **Checkpoint:** on every one of the three VMs, `:9100`, `:9558`, and `:9256` should be
listening and returning data. `:12345` should **not** be listening unless you explicitly flipped
`enable_journald_exporter` on (and even then, only on amd64 hardware).

---

## 5. Verify the role-specific exporters

### 5a. Central only — filestat_exporter

`central` is the only VM with `/var/log/remote`, so it's the only VM running
**filestat_exporter** (`:9943`, flag `enable_filestat_exporter`, default on), which watches that
directory for incoming log files:

```sh
just ssh centralized_logging central
curl -fsS http://localhost:9943/metrics | head
```

### 5b. Docker — cAdvisor + Traefik metrics

```sh
just ssh centralized_logging docker
```

**cAdvisor** (`:8089`, flag `enable_cadvisor`, default on). Note the unusual port: `:8080` is
already taken by the Traefik dashboard on this VM, so cAdvisor was deliberately moved to `:8089`.

```sh
curl -fsS http://localhost:8089/metrics | head
```

**Traefik metrics** (`:8082`, flag `enable_traefik_metrics`, default on):

```sh
curl -fsS http://localhost:8082/metrics | head
```

### 5c. k0s — kube-proxy, kubelet, kube-state-metrics

```sh
just ssh centralized_logging k0s
```

**cAdvisor** (`:8089`, flag `enable_cadvisor`, default on — same `:8080`-is-taken story, this time
by kube-router):

```sh
curl -fsS http://localhost:8089/metrics | head
```

**kube-proxy** and read-only **kubelet** metrics (`:10249` / `:10255`, flag
`enable_kube_metrics`, default on):

```sh
curl -fsS http://localhost:10249/metrics | head
curl -fsS http://localhost:10255/metrics/cadvisor | head
```

**kube-state-metrics** (`:8081`, flag `enable_kube_state_metrics`, default on):

```sh
curl -fsS http://localhost:8081/metrics | head
```

✅ **Checkpoint:** central has `:9943` listening; docker has `:8089` and `:8082`; k0s has `:8089`,
`:10249`, `:10255`, and `:8081`. Nothing else should be answering on those role-specific ports on
the *other* VMs.

---

## 6. syslog-ng metrics: the textfile collector

This is the cleverest piece of the layer, so it's worth understanding, not just curling. syslog-ng
4.1+ (these VMs run **4.3.1**) can dump its own stats in Prometheus format via
`syslog-ng-ctl stats prometheus`. Rather than run a separate exporter process, a systemd timer
(`syslogng-textfile.timer`, every 15s) runs that command and writes the result to a file
node_exporter already knows how to serve:

```sh
/var/lib/node_exporter/textfile_collector/syslogng.prom
```

node_exporter's textfile collector picks that file up and republishes it on its existing `:9100`
— **one port, one binary**, no extra service. Check it on any VM (flag `enable_syslogng_metrics`,
default on):

```sh
cat /var/lib/node_exporter/textfile_collector/syslogng.prom | grep syslogng_
```

```
syslogng_input_events_total{id="s_src#0",source="afsocket_sd_stream_instance"} 42
syslogng_internal_events_total{result="dropped"} 0
syslogng_socket_connections{id="d_central"} 1
```

The same metrics are visible via node_exporter's own `/metrics` on `:9100`:

```sh
curl -fsS http://localhost:9100/metrics | grep syslogng_ | head
```

✅ **Checkpoint:** `syslogng_` series exist and `syslogng_internal_events_total{result="dropped"}`
is `0` (or close to it) — a steadily climbing dropped count would mean syslog-ng is shedding
messages, which is exactly the kind of thing the future alert rules in
[`cloud-init/prometheus/alert.rules.yml`](cloud-init/prometheus/alert.rules.yml) watch for.

---

## 7. Cross-VM reachability: the 0.0.0.0-bind proof

Every exporter above is bound to `0.0.0.0`, not `127.0.0.1` — meaning it's reachable from *outside*
the VM it runs on. That's the whole point of "pull deferred": a future Prometheus living on a
different VM (in a different cluster, even) needs to be able to reach these endpoints over the
network. Prove it now, before that Prometheus exists.

From the host, grab central's IP:

```sh
tofu -chdir=clusters/centralized_logging output -json metrics_targets | jq -r '.central.ip'
```

Then, from a **different** VM (k0s or docker), curl central's node_exporter by IP instead of
`localhost`:

```sh
just ssh centralized_logging k0s
curl -fsS http://<central_ip>:9100/metrics | head
```

If that returns metrics, central's node_exporter is genuinely reachable cross-VM — not just
locally bound. This is precisely what `tests/testinfra/test_metrics.py::test_cross_vm_reachability`
automates (and what `just verify` already ran for you in §2).

✅ **Checkpoint:** the curl from k0s to `<central_ip>:9100/metrics` succeeds. If it times out or
refuses, see [§8](#8-troubleshooting).

---

## 8. Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| A port isn't listening yet right after `just up` | cloud-init is still installing that exporter's binary | `just up` already waits on `cloud-init status --wait`; if you bypassed that or jumped in early, `just ssh <role>` then `sudo cloud-init status --long` and retry once it's `done` |
| A port isn't listening **and cloud-init is done** | the corresponding `enable_*` flag is off | check `tofu -chdir=clusters/centralized_logging output -json enabled_exporters` — if the name is missing, the exporter was never installed (not a bug) |
| `:12345` (journald-exporter) is never listening | **expected.** `enable_journald_exporter` defaults to `false` because the upstream binary release is x86-64-only and does not run on these arm64 VMs | nothing to fix; flip the flag on real amd64 hardware (e.g. Proxmox) instead |
| `multipass exec` / `multipass shell` fails with "No route to host" | a Multipass daemon networking quirk on this host | SSH directly with the injected key: `ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@<ip>`, where `<ip>` comes from `just status` or `tofu output`. `just ssh` already does this for you, and `just verify` uses direct SSH too, so it's unaffected. |
| `curl: (7) Failed to connect` from another VM but `localhost` works fine | exporter accidentally bound to `127.0.0.1` instead of `0.0.0.0`, or a stale `ss -tlnp` read | re-check `sudo ss -tlnp` for the `*:<port>` form (not `127.0.0.1:<port>`); this would be a real regression worth filing, since the whole design assumes `0.0.0.0` |
| `just verify` hangs early | a VM isn't SSH-reachable yet | `conftest.py` polls SSH for up to 120s and `cloud-init status --wait` for up to 600s — give it time, or check `just status` for a VM stuck in a non-`Running` state |

---

## What's next: wire the monitoring cluster to scrape

Everything above proves the *targets* exist and answer — nothing is scraping them yet, by design.
The repo ships two paste-in artifacts for the future `centralized_monitoring` cluster's
Prometheus:

- [`cloud-init/prometheus/logging-scrape.yml`](cloud-init/prometheus/logging-scrape.yml) — one
  `scrape_configs` job per exporter group, with `<central_ip>` / `<docker_ip>` / `<k0s_ip>`
  placeholders.
- [`cloud-init/prometheus/alert.rules.yml`](cloud-init/prometheus/alert.rules.yml) — alert rules
  for syslog-ng service health, dropped events, and clients that stop shipping logs.

To use them: pull the real IPs with `tofu -chdir=clusters/centralized_logging output -json
metrics_targets`, substitute them into the placeholders, and drop both files into the future
monitoring cluster's Prometheus configuration. No changes are needed here — the exporters are
already listening on `0.0.0.0` and waiting.

For the full architectural reasoning behind every decision in this tutorial (why textfile over a
dedicated syslog-ng exporter, why cAdvisor moved to `:8089`, why journald-exporter defaults off),
read [`../../specs/centralized_logging_metrics.md`](../../specs/centralized_logging_metrics.md).
For everything else about this cluster — lifecycle, log-shipping internals, configuration
reference — see [`USAGE.md`](USAGE.md) and the quick-reference [`README.md`](README.md).
