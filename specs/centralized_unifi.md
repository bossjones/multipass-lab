# Plan: `centralized_unifi` cluster — version-exact UniFi USG (rsyslog 5.8.11) + Controller (syslog-ng 3.28.1) simulation

## Task Description

Stand up a new **`centralized_unifi`** cluster (two small Multipass VMs) that reproduces the log plane
of a UniFi homelab **as faithfully as possible — down to the exact daemon versions** — so the
syslog/rsyslog shipping behaviour and the syslog-ng Prometheus exporter can be prototyped locally
against the same software the real gear runs:

- **`usg`** — a UniFi **Security Gateway** stand-in running **rsyslog 5.8.11** (the exact Debian 7
  "wheezy" package, `5.8.11-3+deb7u2`), configured from the real USG (`ubnt`): `imuxsock` + `imklog`,
  `RepeatedMsgReduction`, traditional file format, and the Vyatta rule that fans `*.debug;local7.debug`
  out to both a remote collector and `/var/log/messages`. It is the log **source/forwarder**.
- **`controller`** — a UniFi **Cloud Key Gen2 / Controller** stand-in running **syslog-ng 3.28.1**
  (the exact Debian 11 "bullseye" package, `3.28.1-2+deb11u2` — the same revision string the real
  `UCKG2` reports), configured from the real UCK: the full `conf.d/*.conf` facility fan-out plus the
  `not2msg` macro. It **also** acts as the central collector (adds a `network()` source on `:514`) and
  carries the **Prometheus metrics exporter** we are validating.

Both exact-version daemons run inside their VM as **Debian containers** (see *Fidelity model*), while
the Ubuntu VM itself provides SSH, host metrics, and the Docker runtime. The real configs live in
[`logs/from_unifi/`](../logs/from_unifi/) and are the fixtures this cluster adapts.

This follows the repo's per-cluster conventions from [`specs/centralized_logging.md`](./centralized_logging.md)
and [`specs/centralized_logging_metrics.md`](./centralized_logging_metrics.md): vendored cluster
folder, runtime IP injection, two-layer (hermetic + testinfra) tests, orchestrated by folder name.

## Objective

`just up centralized_unifi` provisions **2** Multipass VMs in one `tofu apply`:

1. `centralized-unifi-controller` — Ubuntu 24.04 VM running a **syslog-ng 3.28.1** container
   (bullseye, native arm64) that applies the UCK's fan-out **and** receives the USG's forwarded logs,
   with a working legacy-stats `/metrics` view of syslog-ng's own counters.
2. `centralized-unifi-usg` — Ubuntu 24.04 VM running an **rsyslog 5.8.11** container (wheezy, emulated
   amd64) generating traffic and forwarding it (UDP/514) to the controller, exactly as the real USG's
   `vyatta-log.conf` does.

`just verify centralized_unifi` proves, live over SSH: the exact versions are running
(`syslog-ng --version` → 3.28.1, `rsyslogd -version` → 5.8.11); the controller receives the USG's
logs; and the syslog-ng exporter's counters increment as traffic flows.

---

## Feasibility answer (updated for the "as similar as possible" goal)

> *"We can repro the versions if we do a custom compilation on the VMs, right? Let's make it as similar as possible."*

**Yes, you can compile — but for maximum similarity, don't. The real appliances don't run
upstream-compiled binaries; they run Debian's packaged builds, and those exact packages are one
`apt install` away on the matching Debian release.** Compiling upstream `5.8.11`/`3.28.1` on Ubuntu
24.04 yields a *different* build (different Debian patches, module set, libc, hardening flags) that
merely shares a version string — and it means a real fight with GCC 14 / OpenSSL 3 / PCRE2. The most
faithful reproduction is **the exact Debian package on the exact Debian userland**:

| Appliance | Real version | Exact source (no compile) | Confirmed by |
|---|---|---|---|
| USG rsyslog | **5.8.11-3+deb7u2** | Debian **7 wheezy** (EdgeOS was wheezy-based pre-v2.0.0) | [UISP EdgeOS/Debian](https://help.uisp.com/hc/en-us/articles/22591219068055-EdgeRouter-Add-Debian-Packages-to-EdgeOS) · [packages.debian.org/wheezy/rsyslog](https://packages.debian.org/wheezy/rsyslog) |
| UCK syslog-ng | **3.28.1-2+deb11u2** | Debian **11 bullseye** | your own `syslog-ng --version` (revision `3.28.1-2+deb11u2`) |

### Two constraints that shape the delivery (both verified)

1. **Multipass on macOS can't boot a Debian VM.** Custom-qcow2 / image-URL launching works on the
   Linux QEMU driver but is historically unsupported on macOS ([canonical/multipass#1260](https://github.com/canonical/multipass/issues/1260),
   [HN](https://news.ycombinator.com/item?id=21838427)). So the period Debian userland runs **inside**
   the Ubuntu VM (as a container), not as the VM's own OS.
2. **Apple Silicon (arm64) has no wheezy build.** bullseye has arm64 → the **syslog-ng 3.28.1 controller
   runs native**. wheezy predates arm64 → the **rsyslog 5.8.11 USG runs emulated** (amd64 wheezy under
   qemu-user/binfmt). EOL wheezy installs from `archive.debian.org` via the `debian/eol:wheezy` image
   ([Docker Hub](https://hub.docker.com/r/debian/eol/)); a low-rate syslog forwarder is unbothered by
   the emulation overhead.

**Chosen approach (per your selections): containers + emulated amd64 wheezy.** See *Fidelity model*
for the tiers and the `version_mode` toggle that also keeps the modern-syslog-ng path available.

### The exporter consequence — now version-faithful too (and it changes the answer)

Because the controller now runs the **real 3.28.1**, the modern exporters from the blog posts
(`syslog-ng-ctl stats prometheus`, the `stats-exporter()` source, **czanik/sngexporter** — all
**OSE 4.1+**) **do not apply** — exactly as on the real UCK. The version-exact lab therefore validates
the path you'd actually deploy on the appliance: a **legacy-CSV stats exporter**,
**[brandond/syslog_ng_exporter](https://github.com/brandond/syslog_ng_exporter)** (Go), which reads
the old `syslog-ng-ctl stats` output over syslog-ng's control socket and serves Prometheus on `:9577`.
This is strictly better for your goal than the earlier "run 4.x for the nice native exporter" idea:
the lab now matches the appliance's exporter constraints, not just its configs.

> To get useful per-source/destination counters out of 3.28.1's legacy stats, raise the stats level in
> the lab `options {}` (`stats(level(1))` / `stats_level(1)`). The appliance ships `stats_freq(0)`
> (periodic logging off); on-demand `STATS` still returns counters, so this is a small lab-only tweak.

rsyslog on the USG stays a pure source (its metrics are observed at the collector); rsyslog 5.8.11 has
no `/metrics` and needs none here. **No different log shipper is required.**

---

## Fidelity model (`version_mode` + the tier you picked)

A single `version_mode` variable selects how the daemons are delivered:

| `version_mode` | What runs | syslog-ng exporter | Use it for |
|---|---|---|---|
| **`exact`** (default) | Debian-packaged **rsyslog 5.8.11** (wheezy, emulated amd64) + **syslog-ng 3.28.1** (bullseye, native arm64) in containers | legacy CSV → `brandond/syslog_ng_exporter` :9577 | matching the real appliances (this spec's goal) |
| `modern` | Ubuntu-stock **rsyslog 8.x** + **syslog-ng 4.x** on the bare VM | native `syslog-ng-ctl stats prometheus` via node_exporter textfile (:9100) | prototyping the modern native exporter |

**Delivery = containers** (your choice). Each daemon runs in a Docker container built `FROM` the exact
Debian release, `--network host` (so `:514` and the control socket live on the VM's network), with the
rendered config bind-mounted in. This mirrors the repo's existing Docker precedent
(`centralized_logging`'s docker-client) and is reproducible + arm64-aware. Documented alternatives, not
built by default: **`systemd-nspawn`** (higher fidelity — real `syslog-ng.service` under systemd/journald
on bullseye) and **source compilation** (exact version string, non-Debian build, toolchain-heavy).

### Where the exact versions come from (prebuilt image vs. build-from-Debian)

For each daemon there's a choice between pulling a pre-tagged image and building `FROM` the matching
Debian release. **This plan builds from Debian** — it is the more faithful and more arm64-friendly path:

| Daemon | Prebuilt image | Build-from-Debian (**chosen**) | Why build wins |
|---|---|---|---|
| syslog-ng 3.28.1 | [`balabit/syslog-ng:3.28.1`](https://hub.docker.com/r/balabit/syslog-ng/tags) — **upstream** build on Debian **Buster**, ~**amd64-only** | `FROM debian:bullseye` → `apt install syslog-ng=3.28.1-2+deb11u2` | build = the UCK's *actual* bullseye package (real patches/modules/libc), **native arm64**, pinned/reproducible. The balabit tag matches only the version number, on the wrong base, and would **emulate** on Apple Silicon. |
| rsyslog 5.8.11 | **none exists** (official `rsyslog/rsyslog` is 8.x only; 5.8.11 predates Docker) | `FROM debian/eol:wheezy` → `apt install rsyslog=5.8.11-3+deb7u2` | the only route to the exact version at all. |

So a prebuilt image is a convenience only for syslog-ng, and even there it is a fidelity *downgrade*
(upstream/Buster/amd64) vs. building the real bullseye package. The Dockerfiles below are two lines each;
the `--build` cost is a one-time first boot. (If you ever prefer the prebuilt syslog-ng image anyway,
swap the controller `build:` for `image: balabit/syslog-ng:3.28.1` — accept the Buster/amd64 caveat.)

The rest of this plan describes `version_mode = exact`.

---

## Problem Statement

Before wiring the real USG and UCK — appliances that are awkward and risky to experiment on — we want
a cheap, disposable local rig that reproduces the two devices' **exact syslog software, configs, and
forwarding behaviour**, and answers definitively whether a syslog-ng Prometheus exporter is usable on
the UCK's syslog-ng 3.28.1. The earlier version of this plan simulated behaviour on modern packages;
the goal now is version-exact fidelity so the lab's findings transfer 1:1 to the appliances.

## Solution Approach

A **self-contained 2-VM cluster** under `clusters/centralized_unifi/`, each Ubuntu 24.04 VM hosting a
period-exact Debian container:

```
   centralized-unifi-usg  (Ubuntu VM, arm64)                 centralized-unifi-controller  (Ubuntu VM, arm64)
   ┌──────────────────────────────────────┐                 ┌──────────────────────────────────────────────┐
   │ docker: FROM debian/eol:wheezy        │  UDP/514 (@,    │ docker: FROM debian:bullseye  (native arm64)   │
   │   platform=linux/amd64 (emulated)     │   RFC3164)      │   syslog-ng 3.28.1-2+deb11u2                   │
   │   rsyslog 5.8.11-3+deb7u2             │ ───────────────▶│   UCK conf.d fan-out + not2msg                 │
   │   vyatta-log.conf → ${controller_ip}  │                 │   network() source :514  → /var/log/remote/…   │
   │   + traffic generator                 │                 │ docker: brandond/syslog_ng_exporter :9577      │
   │ host: node_exporter :9100             │                 │   (legacy STATS over the control socket)       │
   └──────────────────────────────────────┘                 │ host: node_exporter :9100                      │
                                                             └──────────────────────────────────────────────┘
```

- **Exact packages, pinned.** Controller container: `apt-get install syslog-ng=3.28.1-2+deb11u2`
  (bullseye is native arm64, so apt works normally). USG container: the exact
  `rsyslog_5.8.11-3+deb7u2_amd64.deb` is **fetched natively on the arm64 VM host** (`curl` from
  `archive.debian.org`) and unpacked with `dpkg-deb -x` into the image — **not** `apt-get install`.
  **Why:** Debian wheezy's apt `http` transport **segfaults under qemu-user emulation**
  (`Sub-process http received a segmentation fault`) regardless of qemu version, so no apt runs inside
  the emulated container. rsyslog 5.8.11's only real runtime deps are `libc6` + `zlib1g` (both in the
  base image; `lsb-base`/`initscripts` are only used by the sysvinit script, which we don't run), so a
  plain `dpkg-deb -x` overlay is sufficient. Version pins make the build reproducible; the live tests
  assert the running `--version`.
- **Real configs, one adaptation.** The USG's `rsyslog.conf` + `vyatta-log.conf` and the UCK's
  `syslog-ng.conf` + `conf.d/*` + `not2msg` are bind-mounted into the containers verbatim, except the
  Vyatta forward target `@192.168.3.16:514` is rewritten to the injected controller IP.
- **Controller doubles as collector.** One added `network()` source (udp+tcp `:514`) + a `d_remote`
  file sink (`/var/log/remote/$HOST/$PROGRAM.log`, the MVP sink from `centralized_logging`) on top of
  the UCK's stock local fan-out, plus `stats(level(1))` so the legacy exporter has counters to read.
- **Runtime IP injection** (copied from `centralized_logging`): OpenTofu creates `controller` first,
  reads its `ipv4`, and renders the USG's `vyatta-log.conf` from it — the
  `templatefile → local_file → controller.ipv4` reference orders a single `tofu apply` correctly.
- **Version-faithful metrics.** `brandond/syslog_ng_exporter` runs as a sidecar container sharing the
  syslog-ng control-socket volume, exposing `:9577` — the exporter you'd run on the real UCK.
  `node_exporter` runs on each VM host for OS metrics. All listeners bind `0.0.0.0` for a future scrape.
- **Traffic generator** in the USG container emits Vyatta/firewall-style `logger` lines — including
  `local7` facility and the `[ALIEN BLOCK]` / `[TOR BLOCK]` markers the UCK `not2msg` filters on — so
  the pipeline shows live data and the exporter counters move.

---

## Relevant Files

### Reference fixtures (the real appliance configs — bind-mount, adapt only the forward target)
- [`logs/from_unifi/usg/etc/rsyslog.conf`](../logs/from_unifi/usg/etc/rsyslog.conf) — USG base rsyslog.
- [`logs/from_unifi/usg/etc/rsyslog.d/vyatta-log.conf`](../logs/from_unifi/usg/etc/rsyslog.d/vyatta-log.conf)
  — `*.debug;local7.debug @192.168.3.16:514` (UDP) + `-/var/log/messages`. **Rewrite `@192.168.3.16` →
  `${controller_ip}`.**
- [`logs/from_unifi/controller/etc/syslog-ng/syslog-ng.conf`](../logs/from_unifi/controller/etc/syslog-ng/syslog-ng.conf)
  — UCK main config (`@version: 3.27`, `options{}`, `s_src`, `f_*` filters, `@include conf.d/*.conf`).
- `logs/from_unifi/controller/etc/syslog-ng/conf.d/*.conf` — facility fan-out.
- `logs/from_unifi/controller/etc/syslog-ng/not2msg/{main,uled-control}` — the `not2msg` confgen macro.

### Pattern sources (copy structure/mechanism)
- [`clusters/centralized_logging/main.tf`](../clusters/centralized_logging/main.tf) — locals, IP
  injection, `local.flags` merge, `local_file`/`multipass_instance` wiring. **Primary template.**
- [`clusters/centralized_logging/cloud-init/docker-client.yaml.tftpl`](../clusters/centralized_logging/cloud-init/docker-client.yaml.tftpl)
  — the Docker-on-Ubuntu install + compose-splice + gz+b64 file-write patterns to reuse for both VMs.
- [`clusters/centralized_logging/cloud-init/central.yaml.tftpl`](../clusters/centralized_logging/cloud-init/central.yaml.tftpl)
  — node_exporter install (`install-exporter.sh`), `@include conf.d` guard, late `timedatectl` UTC fix.
- [`clusters/centralized_logging/cloud-init/syslog-ng/server.conf.tftpl`](../clusters/centralized_logging/cloud-init/syslog-ng/server.conf.tftpl)
  — the `network()` source + `d_remote` sink to merge into the UCK config.
- [`clusters/centralized_logging/{variables.tf,outputs.tf,versions.tf}`](../clusters/centralized_logging/)
  — variable/flag/output/provider shapes; provider pins (`multipass ~> 1.4`, `local ~> 2.4`, tofu ≥ 1.7).
- [`clusters/centralized_logging/tests/tofu/sizing_and_render.tftest.hcl`](../clusters/centralized_logging/tests/tofu/sizing_and_render.tftest.hcl)
  — hermetic assertion style (`mock_provider`, `command = plan`, `strcontains`, `can(yamldecode())`).
- [`clusters/centralized_logging/tests/testinfra/conftest.py`](../clusters/centralized_logging/tests/testinfra/conftest.py)
  — `tofu output -json` → SSH-host fixtures. Adapt roles to `controller`/`usg`.
- [`Justfile`](../Justfile) — generic recipes dispatch by folder name; **no edit needed** for
  `up`/`check`/`verify`/`destroy`/`recreate`/`prune`/`ssh`/`open` (`just ssh centralized_unifi controller`).

### New Files (under `clusters/centralized_unifi/`)
- `versions.tf`, `providers.tf`, `variables.tf`, `terraform.tfvars`, `main.tf`, `outputs.tf`, `README.md`
- `cloud-init/controller.yaml.tftpl` — Ubuntu host: Docker + node_exporter; renders the syslog-ng +
  exporter compose stack.
- `cloud-init/usg.yaml.tftpl` — Ubuntu host: Docker + qemu-user-static/binfmt + node_exporter; renders
  the rsyslog compose stack + generator.
- `cloud-init/controller/` — `Dockerfile.syslogng` (`FROM debian:bullseye`, pinned install),
  `compose.yaml.tftpl` (syslog-ng + syslog_ng_exporter), `uck.conf.tftpl` (adapted fan-out + `not2msg`
  + `network()` source + `d_remote` + `stats(level(1))`).
- `cloud-init/usg/` — `Dockerfile.rsyslog` (`FROM --platform=linux/amd64 debian/eol:wheezy`, archive
  sources + pinned install), `compose.yaml.tftpl` (rsyslog + generator), `rsyslog.conf`,
  `vyatta.conf.tftpl` (`${controller_ip}`), `unifi-gen.sh`.
- `tests/tofu/sizing_and_render.tftest.hcl` — hermetic (sizing, names, pinned images/versions, IP
  injection, valid YAML, flag/mode gating).
- `tests/testinfra/{pyproject.toml,conftest.py,test_controller.py,test_usg.py,test_e2e_shipping.py,test_metrics.py}`

---

## Implementation Phases

### Phase 1: Foundation
Scaffold the folder + provider pins; two bare Ubuntu VMs with Docker installed; the runtime
IP-injection edge (`usg` renders `controller.ipv4`); a hermetic sizing/names test. Prove
`just up/check/verify` dispatch to the new folder.

### Phase 2: Core Implementation (exact-version containers)
Render + build the two Debian containers with pinned versions and the real configs; controller receives
UDP/514 into `/var/log/remote`; USG forwards + generates traffic; `brandond/syslog_ng_exporter` sidecar
on `:9577`; node_exporter on both hosts. Extend hermetic tests to assert every pinned marker + IP
injection.

### Phase 3: Integration & Polish
testinfra: containers healthy, exact `--version` strings, `:514` listening, E2E shipping (USG token →
controller `/var/log/remote/`), exporter counters climbing. README documenting the version-exact design,
the arm64 emulation caveat, and the legacy-vs-modern (`version_mode`) exporter split.

---

## Step by Step Tasks

IMPORTANT: Execute every step in order, top to bottom.

### 1. Scaffold folder + provider pins + variables
- Create `clusters/centralized_unifi/`; copy `versions.tf`/`providers.tf` unchanged.
- `variables.tf`: `name_prefix="centralized-unifi"`, `image="24.04"`, `syslog_port=514`, ssh key vars.
- Sizing (containers + emulation want headroom): `controller={cpus=2,memory="2G",disk="20G"}`,
  `usg={cpus=2,memory="2G",disk="15G"}`.
- `version_mode` (string, default `"exact"`, validation `contains(["exact","modern"], …)`).
- Pinned-version vars for reproducibility + easy bumping:
  `syslogng_deb_version="3.28.1-2+deb11u2"`, `rsyslog_deb_version="5.8.11-3+deb7u2"`,
  `controller_base_image="debian:bullseye"`, `usg_base_image="debian/eol:wheezy"`.
- `enable_node_exporter` (default true), `enable_syslogng_exporter` (default true, controller only),
  `enable_unifi_traffic` (default true).

### 2. Write `main.tf`
- `locals`: `controller_name`/`usg_name`; ssh key resolution + `render_dir`; a `flags`/pins map merged
  into every `templatefile()`.
- Render `controller/compose.yaml.tftpl` + `controller/uck.conf.tftpl` + `Dockerfile.syslogng` with the
  pins + `syslog_port`.
- Render `usg/vyatta.conf.tftpl` with `controller_ip = multipass_instance.controller.ipv4` (the
  IP-injection edge) + `usg/compose.yaml.tftpl` + `Dockerfile.rsyslog`.
- `local_file.controller_ci` → `controller.yaml.tftpl` (merge pins, ssh key, rendered compose/config/
  Dockerfile). `multipass_instance.controller` points at it. **Create controller first.**
- `local_file.usg_ci` → `usg.yaml.tftpl` (merge pins, ssh key, rendered compose/vyatta/Dockerfile/
  generator). `multipass_instance.usg` points at it.

### 3. Author the controller container assets
- `Dockerfile.syslogng`: `FROM ${controller_base_image}` → `apt-get update && apt-get install -y
  syslog-ng=${syslogng_deb_version} syslog-ng-core=${syslogng_deb_version}` → `ENTRYPOINT
  ["syslog-ng","-F","-f","/etc/syslog-ng/syslog-ng.conf"]`.
- `uck.conf.tftpl`: reproduce the UCK `conf.d` fan-out (messages/auth/cron/daemon/kern/mail/news/error/
  debug/console/bash-history) with the `f_*` filters and the `not2msg` expansion inlined into
  `f_messages` (`… and not message("\\[ALIEN BLOCK\\]") …`); **add** `source s_net { network(ip("0.0.0.0")
  transport("udp") port(${syslog_port}) flags(no-parse)); }` + a tcp variant, `destination d_remote {
  file("/var/log/remote/$${HOST}/$${PROGRAM}.log" create-dirs(yes)); }`, `log { source(s_net);
  destination(d_remote); };`, and `options { … stats(level(1)); keep-hostname(yes); }`. (3.28 accepts
  the appliance's own `s_src`/`internal()`; keep it for local fan-out.)
- `compose.yaml.tftpl`: `syslog-ng` service (build `.`, `network_mode: host`, volumes: `uck.conf` →
  `/etc/syslog-ng/syslog-ng.conf`, a named volume for `/var/lib/syslog-ng` control socket,
  `/var/log/remote`), + `syslogng-exporter` service (`brandond/syslog_ng_exporter`, shares the socket
  volume, `--socket-path=/var/lib/syslog-ng/syslog-ng.ctl`, `network_mode: host`, `:9577`), gated on
  `enable_syslogng_exporter`.

### 4. Author the USG container assets
- `Dockerfile.rsyslog`: `FROM --platform=linux/amd64 ${usg_base_image}` → `COPY rsyslog-root/ /`
  (the pre-extracted exact package) → `ENTRYPOINT ["/usr/local/bin/usg-entrypoint.sh"]`. **No apt
  inside the container** — wheezy's apt `http` method segfaults under qemu-user emulation. Instead the
  USG cloud-init `runcmd` fetches `rsyslog_${rsyslog_deb_version}_amd64.deb` **natively on the arm64
  host** (`curl` from `archive.debian.org`, no emulation) and `dpkg-deb -x`s it into
  `/opt/unifi/rsyslog-root` before `docker compose ... up --build`; the Dockerfile does zero emulated
  `RUN` steps, so the build never segfaults (only the runtime `rsyslogd -n` is emulated).
- `rsyslog.conf`: the USG base verbatim (`$ModLoad imuxsock`/`imklog`, `$RepeatedMsgReduction on`,
  `RSYSLOG_TraditionalFileFormat`, `$FileGroup adm`, `$IncludeConfig /etc/rsyslog.d/*.conf`).
- `vyatta.conf.tftpl`: `*.debug;local7.debug  @${controller_ip}:${syslog_port}` (single `@` = UDP,
  faithful) + `*.debug;local7.debug  -/var/log/messages`.
- `unifi-gen.sh`: loop `logger -p local7.info -t vyatta-firewall "[ALIEN BLOCK]-DROP …"`,
  `logger -p daemon.notice -t hostapd …`, `logger -p kern.warning -t kernel …`,
  `logger -p local7.info -t ubnt-dpi …` (at least one line survives `not2msg` to reach the collector).
- `compose.yaml.tftpl`: `rsyslog` service (`platform: linux/amd64`, build `.`, `network_mode: host`,
  bind the two configs) + a `generator` sidecar (or the loop as the rsyslog image's secondary command),
  gated on `enable_unifi_traffic`.

### 5. Author `cloud-init/controller.yaml.tftpl`
- `packages: [docker.io, docker-compose-v2, curl, jq, tar]`; `timezone: Etc/UTC` + systemd-timesyncd;
  inject ssh key.
- `write_files` (gz+b64 like docker-client): `/opt/unifi/Dockerfile`, `/opt/unifi/compose.yaml`,
  `/opt/unifi/uck.conf`, `install-exporter.sh`.
- `runcmd`: `mkdir -p /var/log/remote`; `docker compose -f /opt/unifi/compose.yaml up -d --build`;
  install node_exporter (host `:9100`, gated); late `timedatectl set-timezone Etc/UTC`.

### 6. Author `cloud-init/usg.yaml.tftpl`
- `packages: [docker.io, docker-compose-v2, qemu-user-static, binfmt-support, curl, jq, tar]`; timezone/
  NTP; ssh key.
- `runcmd`: ensure amd64 binfmt is registered (`qemu-user-static` handles it; belt-and-braces
  `docker run --privileged --rm tonistiigi/binfmt --install amd64`); `docker compose -f
  /opt/unifi/compose.yaml up -d --build`; install node_exporter (gated); late `timedatectl` UTC.
- `write_files`: `/opt/unifi/{Dockerfile,compose.yaml,rsyslog.conf,vyatta-log.conf,unifi-gen.sh}`.

### 7. Write `outputs.tf`
- `hosts = {controller={name,ipv4}, usg={name,ipv4}}`; `controller_ipv4`/`usg_ipv4`.
- `version_mode`, `versions = {syslog_ng="3.28.1-2+deb11u2", rsyslog="5.8.11-3+deb7u2"}` (tests assert).
- `metrics_targets = {controller:{ip, exporters:{node=9100, syslog_ng=9577}}, usg:{ip,
  exporters:{node=9100}}}`; optional flag-aware `web_urls`.

### 8. Hermetic test `tests/tofu/sizing_and_render.tftest.hcl`
- `mock_provider "multipass" {}`, inline ssh key.
- Sizing/names/image; both names carry `centralized-unifi-` prefix.
- `controller_ci.content` contains `debian:bullseye`, `syslog-ng=3.28.1-2+deb11u2`, `network(`,
  `/var/log/remote`, `\[ALIEN BLOCK\]`, `stats(level(1))`, `syslog_ng_exporter`, `:9577`, ssh key.
- `usg_ci.content` contains `debian/eol:wheezy`, `platform: linux/amd64`, `archive.debian.org`,
  `rsyslog=5.8.11-3+deb7u2`, the `@` forward with the mocked controller IP (not literal `192.168.3.16`),
  `qemu-user-static`.
- Mode/flag gating: `version_mode="modern"` renders the Ubuntu-stock/native-textfile path and **omits**
  `debian/eol:wheezy`; `enable_syslogng_exporter=false` omits `:9577`; `enable_unifi_traffic=false`
  omits the generator.
- `can(yamldecode())` on both; timezone/NTP markers on both.

### 9. Live testinfra `tests/testinfra/`
- `conftest.py`: `controller`/`usg` fixtures from `hosts`; `metrics_targets` fixture. Give
  cloud-init/build a generous wait (image pull + `--build` + emulated wheezy apt is slow — raise
  `CLOUD_INIT_TIMEOUT`).
- `test_controller.py`: syslog-ng container `Up`; `docker exec … syslog-ng --version` contains
  **`3.28.1`**; host `:514/udp` listening; `/var/log/remote` exists.
- `test_usg.py`: rsyslog container `Up`; `docker exec … rsyslogd -version` contains **`5.8.11`**;
  `vyatta-log.conf` forwards to the controller IP; generator active (when enabled).
- `test_metrics.py`: node_exporter `:9100/metrics` 200 on both; `:9577/metrics` on controller returns
  `syslog_ng_` series (when `enable_syslogng_exporter`); cross-VM reach from usg → controller `:9100`.
- `test_e2e_shipping.py` (**headline**): emit `logger -p local7.info -t e2e <uuid>` inside the USG
  container → poll the controller until `<uuid>` appears under `/var/log/remote/` → then assert the
  `:9577` exporter shows a nonzero received/processed counter.

### 10. `README.md` + validate end-to-end
- Document: the two exact versions + how they're delivered (bullseye native / wheezy emulated), the
  `version_mode` toggle, the legacy-vs-native exporter split, and the `just recreate` cloud-init note.
- Run the validation commands; fix until hermetic + live pass.

---

## Testing Strategy

Two layers, per repo convention.

- **Hermetic (`just check centralized_unifi`, no VMs)** — `tofu fmt -check`, `validate`, and `tofu test`
  with `mock_provider` + `command = plan`. Asserts sizing/names, **every pinned image/version marker**,
  the `${controller_ip}` injection into the Vyatta forward, per-mode/flag render **and absence**, and
  valid YAML.
- **Live (`just verify centralized_unifi`, after `just up`)** — `uv run pytest` over SSH. The headline
  assertions are **exact `--version` strings** (3.28.1 / 5.8.11), **E2E shipping**, and **exporter
  liveness**.

Edge cases:
- **wheezy apt segfaults under qemu (resolved).** Debian wheezy's apt `http` transport dies with a
  segmentation fault under qemu-user emulation (verified on both the Ubuntu `qemu-user-static` and
  `tonistiigi/binfmt` qemu builds). The fix is to never run apt in the emulated container: fetch the
  `.deb` natively on the arm64 host and `dpkg-deb -x` it (see step 4). The base image pull + emulated
  runtime are still slow-ish, so the verify loop tolerates a long first boot.
- **Pinned .deb availability.** The exact `rsyslog_5.8.11-3+deb7u2_amd64.deb` is on
  `archive.debian.org` (verified). If a revision is ever pulled, bump `rsyslog_deb_version`; the live
  test asserts the running `rsyslogd -version` contains `5.8.11`, so a wrong pin fails loudly at build.
- **UDP loss / hostname foldering.** UDP is lossy — E2E polls with retries; `keep-hostname(yes)` means
  the received path uses `centralized-unifi-usg` (assert that, not a raw IP).
- **`not2msg` correctness.** A `[ALIEN BLOCK]` line is excluded from the controller's local
  `/var/log/messages` fan-out but still received over the network path — assert both.
- **`version_mode=modern`** must render the Ubuntu-native path with **no** Debian-container markers
  (hermetic), giving a clean fallback for prototyping the native exporter.

---

## Acceptance Criteria

- `just up centralized_unifi` brings up **two** VMs; the USG forwards to the controller's runtime IP
  (no hardcoded `192.168.3.16`).
- **Exact versions run:** `docker exec … syslog-ng --version` → **3.28.1** on the controller;
  `docker exec … rsyslogd -version` → **5.8.11** on the USG (from the pinned Debian packages).
- The controller applies the UCK `conf.d` + `not2msg` behaviour **and** collects the USG's logs to
  `/var/log/remote/$HOST/$PROGRAM.log`.
- **E2E:** a `logger` token from the USG container appears under `/var/log/remote/` on the controller.
- **Exporter validated on the real 3.28.1:** `brandond/syslog_ng_exporter` serves `:9577` and its
  counters climb under the generator's traffic — the version-faithful answer to the feasibility question.
- `just check` (hermetic) and `just verify` (live) both pass; `version_mode=exact` is the default,
  `modern` is available and hermetic-tested.

---

## Validation Commands

```sh
# --- hermetic (no VMs) ------------------------------------------------------
just check centralized_unifi
tofu -chdir=clusters/centralized_unifi test -test-directory=tests/tofu

# --- live (running VMs; first boot is slow — emulated wheezy build) ---------
just up centralized_unifi
multipass list

# exact versions actually running (the fidelity proof):
just ssh centralized_unifi controller -- 'docker exec unifi-syslog-ng syslog-ng --version | head -1'   # -> 3.28.1
just ssh centralized_unifi usg        -- 'docker exec unifi-rsyslog rsyslogd -version | head -1'        # -> 5.8.11

just verify centralized_unifi          # versions + E2E shipping + exporter counters

# controller received the USG's forwarded logs:
just ssh centralized_unifi controller -- 'sudo find /var/log/remote -type f'
# legacy syslog-ng exporter is serving metrics (the real-UCK exporter path):
just ssh centralized_unifi controller -- 'curl -s localhost:9577/metrics | grep -c syslog_ng_'
# USG forwards to the injected controller IP (not 192.168.3.16):
just ssh centralized_unifi usg -- 'grep @ /opt/unifi/vyatta-log.conf'

# --- teardown ---------------------------------------------------------------
just destroy centralized_unifi
```

---

## Notes

- **Dependencies:** OpenTofu ≥ 1.7, `multipass`, `uv`, `just`, SSH keypair at `~/.ssh/id_ed25519[.pub]`.
  No new tofu providers. No secrets. In-VM: `docker.io` + `docker-compose-v2` on both; `qemu-user-static`
  + `binfmt-support` on the USG for amd64 emulation. testinfra deps via `uv` (copy logging's pyproject).
- **Why containers beat compiling here:** the appliances run Debian's *packaged* rsyslog/syslog-ng; a
  container `FROM` the matching Debian release reproduces that exact artifact (patches, modules, libc),
  whereas an upstream source build only matches the version string and forfeits the rest — while costing
  a GCC 14 / OpenSSL 3 / PCRE2 toolchain fight (worst for rsyslog 5.8.11). `systemd-nspawn` is the
  higher-fidelity opt-in (real `syslog-ng.service`/journald on bullseye); wheezy is sysvinit, so a
  container already represents the USG faithfully.
- **arm64 reality:** bullseye → syslog-ng 3.28.1 runs **native**; wheezy has no arm64 port → rsyslog
  5.8.11 runs **emulated amd64** (qemu-user/binfmt). Fine for a low-rate forwarder; flagged in tests as
  a slow first boot. To go native later, source-compile 5.8.11 for arm64 (a *different* build) or switch
  `version_mode=modern`.
- **`just` recipes need no edits** — they dispatch by folder name and glob-discover clusters. Roles are
  `controller`/`usg`; `just logs` hardcodes a `central` role (use the `find /var/log/remote` spot-check).
- **Editing cloud-init needs `just recreate centralized_unifi`,** not `just up` — the provider keys
  instances on the cloud-init file *path*, not content (same gotcha as `centralized_logging`), and
  recreating the controller changes its DHCP IP, which the USG's baked forward target depends on.
- **Promotion to real gear:** on the real UCK, deploy the same `brandond/syslog_ng_exporter` against its
  stock 3.28.1 (raise `stats_level`) — the lab's exporter path transfers 1:1. Point the USG/UCK at the
  existing `centralized_logging` collector or wire the controller's `:9577`/`:9100` into
  `centralized_monitoring`'s Prometheus via `metrics_targets` (see `specs/cross-cluster.md`,
  `centralized_logging_metrics.md` §9).

### Sources
- syslog-ng Prometheus exporters (all **OSE 4.1+**): https://www.syslog-ng.com/community/b/blog/posts/prometheus-exporter-in-syslog-ng · https://github.com/czanik/sngexporter · https://syslog-ng.github.io/admin-guide/060_Sources/153_stats_exporter/README · https://axoflow.com/blog/syslog-ng-release-4-1
- Legacy-CSV exporter that works on 3.28.1: https://github.com/brandond/syslog_ng_exporter
- Debian package versions: https://packages.debian.org/wheezy/rsyslog (rsyslog 5.8.11-3+deb7u2) · syslog-ng 3.28.1-2+deb11u2 = Debian 11 bullseye
- EdgeOS/USG is Debian-wheezy-based (pre-v2.0.0): https://help.uisp.com/hc/en-us/articles/22591219068055-EdgeRouter-Add-Debian-Packages-to-EdgeOS
- EOL wheezy via archive.debian.org / Docker: https://hub.docker.com/r/debian/eol/ · https://www.debian.org/distrib/archive
- Multipass custom images unsupported on macOS: https://github.com/canonical/multipass/issues/1260
- Companion specs: [`centralized_logging.md`](./centralized_logging.md), [`centralized_logging_metrics.md`](./centralized_logging_metrics.md), [`cross-cluster.md`](./cross-cluster.md)
