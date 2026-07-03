# centralized_unifi

A version-**exact** simulation of a UniFi homelab's log plane: two Multipass VMs reproducing the
UniFi **Security Gateway** (rsyslog **5.8.11**) forwarding syslog to the UniFi **Controller / Cloud
Key Gen2** (syslog-ng **3.28.1**), with a Prometheus exporter on the collector.

Design + rationale: [`specs/centralized_unifi.md`](../../specs/centralized_unifi.md).

## What runs

| VM | Role | Daemon (exact) | How it's delivered |
|----|------|----------------|--------------------|
| `centralized-unifi-controller` | UCK Gen2 / collector | **syslog-ng 3.28.1-2+deb11u2** | container `FROM debian:bullseye` (native arm64) |
| `centralized-unifi-usg` | USG / forwarder | **rsyslog 5.8.11-3+deb7u2** | container `FROM debian/eol:wheezy` (emulated amd64) |

Both daemons run the **actual Debian packages** the appliances run (not upstream builds), delivered
as containers inside the Ubuntu 24.04 VMs. The controller also runs
[`brandond/syslog_ng_exporter`](https://github.com/brandond/syslog_ng_exporter) on `:9577` — the
legacy-CSV exporter that works on syslog-ng 3.28.1 (the modern `syslog-ng-ctl stats prometheus` needs
4.1+, so it's unavailable on the real UCK too). `node_exporter` runs on each VM host (`:9100`).

```
 usg (rsyslog 5.8.11, wheezy)                      controller (syslog-ng 3.28.1, bullseye)
   vyatta-log.conf: *.debug;local7.debug  --UDP/514-->  network() source -> /var/log/remote/<host>/<prog>.log
   + traffic generator                                  + syslog_ng_exporter :9577  (/metrics)
   node_exporter :9100                                  node_exporter :9100
```

The USG's Vyatta forward target is **injected at apply time** from the controller's runtime IP (the
appliance's hardcoded LAN IP is replaced) — the same runtime-IP mechanism as `centralized_logging`.

## Fidelity model (`version_mode`)

- `version_mode = "exact"` (default) — the period Debian packages in containers, as above.
- `version_mode = "modern"` — Ubuntu-stock syslog-ng 4.x / rsyslog 8.x on the bare VM, with the
  native `syslog-ng-ctl stats prometheus` textfile exporter. For prototyping the native path.

Set it in `terraform.tfvars`.

## Quickstart

```sh
just check centralized_unifi     # hermetic: fmt + validate + tofu test (no VMs)
just up centralized_unifi        # one apply -> 2 VMs (first boot is SLOW: emulated wheezy build)
just verify centralized_unifi    # live: exact versions + E2E shipping + exporter counters
just ssh centralized_unifi controller   # shell onto the collector VM
just open centralized_unifi --full      # open the /metrics endpoints
just destroy centralized_unifi
```

Spot-checks (after `just ssh centralized_unifi <role>`):

```sh
# exact versions actually running (the fidelity proof):
sudo docker exec unifi-syslog-ng syslog-ng --version | head -1   # -> 3.28.1
sudo docker exec unifi-rsyslog   rsyslogd -version    | head -1   # -> 5.8.11
# collector received the USG's forwarded logs:
sudo find /var/log/remote -type f
# legacy syslog-ng exporter serving metrics (the real-UCK exporter path):
curl -s localhost:9577/metrics | grep -c syslog_ng_
```

## Notes & caveats

- **First `just up` is slow.** The USG VM builds the wheezy rsyslog image under qemu emulation and
  installs from `archive.debian.org`; the controller pulls `debian:bullseye` and builds natively. The
  testinfra suite waits up to 20 min for cloud-init.
- **Apple Silicon:** bullseye/syslog-ng runs native; wheezy/rsyslog runs **emulated amd64**
  (`qemu-user-static` + binfmt are installed on the USG VM). wheezy has no arm64 port.
- **Editing cloud-init needs `just recreate centralized_unifi`,** not `just up` — the provider keys
  instances on the cloud-init file path, not content, and recreating the controller changes its DHCP
  IP (which the USG's baked forward target depends on).
- **UDP is lossy** (the appliance forwards UDP); the E2E test retries. The collector also listens TCP
  on `:514` for a reliable comparison path.
- **Promotion to the real UCK:** deploy the same `brandond/syslog_ng_exporter` against its stock
  3.28.1 (raise `stats_level`) — the exporter path transfers 1:1.
