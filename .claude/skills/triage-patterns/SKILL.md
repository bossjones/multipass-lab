---
name: triage-patterns
description: Use when you need to interpret a specific provisioning / cloud-init / journalctl log line from a Multipass cluster VM — deciding whether it's a real failure or benign first-boot noise, or mapping a known signature to its root cause. Trigger on questions like "is `<log line>` a real problem or just noise?", "what does `<error>` mean / what usually causes it", "map this to a root cause", "which journalctl lines actually matter vs benign warnings", or "is this stuck `activating` oneshot expected or hung?". Covers the repo's canonical failures (otelcol EnvironmentFile-missing, otelcol `adm`/syslog permission-denied, stuck cloud-init oneshots, DNS boot-time races, `manifest unknown`/image-pull errors) and the ~20 strong failure signatures. This is the reference/knowledge skill (also preloaded into the log-researcher subagent for identical triage); it does NOT sweep VMs itself — for a full "go investigate why the cluster is broken" across VMs, use the `triage-logs` skill instead.
capabilities: ["log-triage", "failure-signature-reference", "root-cause-mapping"]
---

# Provisioning-log triage patterns

This is the shared "what does this log line actually mean" reference for this repo's Multipass
clusters. It's the single source of truth behind `tools/system_debug.py`'s signature matching and
the `triage-logs` skill's root-cause step. The goal is to move from a raw log line to a *named
cause* fast — the way `permission denied` on `/var/log/syslog` is obviously "the collector user
isn't in `adm`" once you've seen it once.

## Strong failure signatures (signal, not noise)

These are the substrings `tools/system_debug.py` treats as smoking guns. They're deliberately
**specific** — not bare `error`/`warning` — so a clean boot with benign warnings still reports
healthy. When you see one in a `journalctl`/`cloud-init` sweep, it is almost always worth citing:

`permission denied` · `failed to` · `failed with` · `cannot open` · `cannot access` ·
`no such file` · `connection refused` · `connection reset` · `timed out` ·
`operation not permitted` · `address already in use` · `oom` · `out of memory` ·
`manifest unknown` · `error pulling` · `pull access denied` · `no route to host` ·
`x509` · `fatal` · `segfault` · `core dump`

If a line matches one of these, don't stop at "there's an error" — map it to a cause using the
table below, or reason from the specific text. The signature is the *starting* point of a
diagnosis, not the diagnosis itself.

## Canonical root-cause mappings

These are the failures that actually recur on this repo's clusters. Match the log line to the
cause, then propose the *minimal* fix.

**Example 1 — otelcol missing its env file**
Input: `otelcol-contrib … Failed to load environment files: No such file or directory`
Cause: the collector's `EnvironmentFile=` (e.g. `/etc/otelcol-contrib/otelcol.env`) was never
written by cloud-init, so the unit can't start. Fix: ensure cloud-init writes that env file before
the unit starts (a `write_files` entry or an ordering fix), then restart the unit.

**Example 2 — otelcol can't read the syslog it tails**
Input: `otelcol … open /var/log/syslog: permission denied`
Cause: the `otelcol-contrib` user isn't in the `adm` group (or lacks an ACL) for the log file its
`filelog/host` receiver tails. This is the exact class of bug commit `d873e6b` fixed by adding
`otelcol-contrib` to `adm`. Fix: add the user to `adm` (or grant an ACL) in cloud-init.

**Example 3 — a oneshot stuck `activating`**
Input: a unit shows in `systemctl --state=activating` and never reaches `active`; the sweep's
`ACTIVATING` section lists it (common for `netbox-stack.service`, `*-provision` oneshots).
Cause: its `ExecStart` script is blocking inside its own idempotent retry loop — often a slow
image pull, a peer that isn't up yet, or a step waiting on a resource. This is expected *briefly*
(the netbox stack launches async via a systemd oneshot with `--no-block` because its image pull
exceeds Multipass's 300s launch window), but a unit that sits `activating` with no new journal
output for minutes is stuck. Fix: SSH in and `sudo journalctl -u <svc> -b` for the live tail to
see which step is blocking; patch the `/opt/...` file or `/usr/local/sbin/<svc>.sh` and
`sudo systemctl restart --no-block <svc>`.

**Example 4 — DNS boot-time races**
Symptom: early-boot steps fail to resolve names / `no route to host` right after launch, then
recover. Signatures: `curl: (6) Could not resolve host: <host>` (e.g. `get.k0s.sh`,
`docs.k0sproject.io`, `registry-1.docker.io`), or a `SERVFAIL`. Cause: a cross-cluster consumer
points its resolver at the `centralized_dns` AdGuard hub, but a boot-ordering race lets a step run
before AdGuard/Unbound is warm (the class commits `bcd66f7` / `d18943d` addressed with a
`until getent hosts <host>; do sleep 2; done` gate after the `systemctl restart systemd-resolved`).
Distinguish a genuine misconfig from a transient race: re-run the resolution by hand (`getent hosts
<host>` a few times, and `dig @<dns_ip> <host>`) — if it now answers reliably, it was the warm-up
race, and the fix is a resolver-ready gate (or retry) before that step, **not** a broken resolver.

**Example 4b — a network install that lost the race leaves a SILENT infinite wait loop**
Symptom: a VM sits at `cloud-init status: running` for many minutes with **no `--failed` unit** and
the sweep looks "clean" — but nothing finishes. This is the nastiest variant: a one-shot installer
(e.g. `curl https://get.k0s.sh | sh`) lost the DNS race and failed *without aborting* the runcmd
(cloud-init runcmd is `/bin/sh`, no `set -e`), so a **later** `until <cmd>; do sleep 5; done` wait
(e.g. `until k0s kubectl get --raw=/readyz`) loops forever because the thing it waits for was never
installed. Because the loop is silent, `journalctl`/`cloud-init-output.log` stop advancing and
`system_debug` reports no signature. Investigation recipe (this is the "which logs to look at"):
  1. `cloud-init status --long` → `running` + `extended_status: degraded` = an earlier non-fatal error.
  2. `ps -o pid,ppid,args -ax | grep -E 'runcmd|sleep'` → if `/bin/sh …/scripts/runcmd` is alive
     with a child `sleep`, the **main runcmd** is stuck in a wait loop (not a background oneshot).
  3. Read `/var/lib/cloud/instance/scripts/runcmd` and find the `until … sleep` line — that names
     what it's waiting for (e.g. `/usr/local/bin/k0s …`).
  4. Grep `/var/log/cloud-init-output.log` for the *earlier* step that produces it (`grep -nE
     'k0s|get\.k0s|Could not resolve|not found'`) — the real failure (e.g. line 421 `curl: (6)
     Could not resolve host: get.k0s.sh` → `runcmd: 6: /usr/local/bin/k0s: not found`).
Fix: add the resolver-ready gate + a retry loop around the installer; live-repair by running the
missed install by hand so the wait loop's condition finally becomes true and cloud-init completes.

**Example 5 — container image pull failures**
Input: `manifest unknown` / `error pulling` / `pull access denied`
Cause: a pinned image ref is wrong/unavailable, or the registry is unreachable. Fix: check the ref
in the cluster's cloud-init/compose and that the VM has egress.

## What counts as noise (do NOT flag)

A healthy first boot is noisy. Don't raise these as the root cause:

- Benign cloud-init `warning`s that don't match a strong signature and don't block a unit.
- Transient failures immediately followed by a successful retry (idempotent oneshots log their
  own retries — a single `failed to connect` that then succeeds is the retry loop working, not a
  bug). Read a few lines *past* the hit before concluding.
- Units that are briefly `activating` early in boot but making forward progress (new journal
  output each check).
- Kernel/apparmor first-boot chatter unrelated to the cluster's services.

The health rule `tools/system_debug.py` uses: a target is healthy iff it's reachable **and**
`cloud-init status` is `done` **and** there are no `--failed` units **and** no signature hits. If
you can't tie a line to a named cause, say so and point at the `↳ dig deeper` hint rather than
inventing one — a confident wrong cause is worse than an honest "inconclusive, dig here."
