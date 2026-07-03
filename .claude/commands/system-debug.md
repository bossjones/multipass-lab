---
description: SSH into a cluster's VM(s), sweep provisioning journals, and surface the root cause fast (3 tries, exp backoff).
argument-hint: <cluster> [role]
allowed-tools: Bash, Read, AskUserQuestion
---

# /system-debug — fast provisioning-log triage

Diagnose intermittent provisioning problems on a cluster's Multipass VM(s) by reading the
journals that matter — the way a `permission denied` or a missing env-file is obvious the moment
you see it. Follow the **systematic-debugging** discipline: gather evidence → name the root cause
→ propose the *minimal* fix → verify. Do not guess a fix before you have the smoking-gun line.

`$ARGUMENTS` is `<cluster> [role]` — e.g. `centralized_pki services`, or just `centralized_pki`
to sweep every role.

## Phase 1 — Collect evidence (background)

Run the sweeper **in the background** (Bash tool with `run_in_background: true`) so the retry
loop (up to 3 attempts with exponential backoff, ~≤20s of waiting) doesn't block. It early-exits
the moment the VM looks healthy. You'll be re-invoked when it finishes; then read its output.

```bash
uv run tools/system_debug.py $ARGUMENTS --json
```

The script resolves VM IPs from `tofu output -json hosts`, SSHes in, sweeps `cloud-init status`,
`otelcol-contrib`, any `systemctl --failed` units, and a `journalctl -p err` boot sweep, then
**highlights** lines matching known failure signatures. It prints a human report (stderr) plus a
JSON summary (stdout). Exit codes: **0** healthy · **2** issues found · **3** unreachable ·
**4** usage/cluster-not-up.

If exit is **4** (`no hosts output` / `unknown cluster`): the cluster likely isn't up — tell the
user and stop (offer `just up <cluster>`). If **3** (unreachable): the VM may still be booting;
mention it and offer to re-run.

## Phase 2 — Name the root cause

From the highlighted `signature_hits` and `failed_units`, state the actual root cause in plain
terms, not just the log line. Examples:
- `otelcol-contrib … Failed to load environment files: No such file or directory` → the collector's
  `EnvironmentFile=` (e.g. `/etc/otelcol-contrib/otelcol.env`) was never written by cloud-init.
- `otelcol … open /var/log/syslog: permission denied` → the `otelcol-contrib` user isn't in `adm`
  / lacks an ACL on the log file the `filelog/host` receiver tails.
- a oneshot stuck in `still activating` → its `ExecStart` script is blocking in its retry loop
  (SSH in and `journalctl -u <svc>` for the live tail).

Cite the exact line(s). If nothing is conclusive, say so and point at the `↳ dig deeper` hint the
script printed rather than inventing a cause.

## Phase 3 — Ask how far to go, then act

Before changing anything, use **AskUserQuestion** to confirm remediation scope:

- **Report only** — stop here; the user drives the fix.
- **Apply a safe live fix over SSH now** — patch the file under `/opt/...` or
  `/usr/local/sbin/<svc>.sh` and `sudo systemctl restart --no-block <svc>` (the repo's fast
  live-iteration loop). Then **re-run this command** to verify the signature is gone.
- **Fix and fold back into the `.tftpl`, then recreate** — apply the live fix, port it into the
  cluster's `cloud-init/*.tftpl`, and `just recreate <cluster>` (needed for cloud-init changes).

Only act after the user chooses. After any fix, verify by re-running the sweeper and confirming
the exit code is `0` (or the specific signature is gone) — evidence before claiming it's fixed.
