---
name: triage-logs
description: Use when a Multipass cluster in this repo is broken, stuck, unhealthy, or erroring and the user wants you to find out WHY by investigating the logs across its VMs. Trigger on any ask to figure out what broke after `just up` / `just recreate` / `just up-connected`, why a role's VM never came up or looks half-up/unhealthy, or why cloud-init, otelcol, or a systemd unit/oneshot is failing on boot — and especially any request to sweep journalctl across all the VMs, dig through the journals on each role, or run a parallel or multi-VM log investigation of a whole cluster. Handles casual, vague, or misspelled phrasings ("the dns box is borked again", "why is centralized_x misbehaving", "check the logs across the vms", "the netbox VM never came up"). It fans out cheap haiku log-researcher subagents to investigate every suspect role in parallel and returns one distilled root cause plus a minimal fix, instead of dumping raw journals into the conversation. Prefer this over the single-shot `/system-debug` command when several roles or units are suspect; for interpreting a *single* log line or judging "is this signal or noise", use the `triage-patterns` reference skill instead.
capabilities: ["parallel-log-triage", "root-cause-synthesis", "remediation"]
---

# triage-logs — parallel provisioning-log triage

Diagnose a misbehaving Multipass cluster fast by fanning out **haiku** researcher subagents (one
per suspect role) that read the journals in parallel, and keeping the verbose output *in their
contexts* — only distilled, cited findings return to you. You (the main agent, opus) verify those
citations, name the root cause, and drive the fix.

Follow the **systematic-debugging** discipline throughout: gather evidence → name the root cause
→ propose the *minimal* fix → verify. Never guess a fix before you have the smoking-gun line.

`$ARGUMENTS` is `<cluster> [role]` — e.g. `centralized_dns`, or `centralized_pki services` to
focus one role.

## Why this shape (subagent discipline — standing rules)

Subagents start with **zero** context from this conversation and can't coordinate mid-task, so a
few rules are load-bearing, not optional:

- **Partition up front, delegate explicitly.** Each researcher gets ONE role and a self-contained
  prompt naming the exact cluster, role, and suspect unit(s). Don't say "check the logs" — say
  "role `services` on `centralized_pki`, suspect units `netbox-stack.service`, `otelcol-contrib`."
- **Summaries, never dumps.** The whole point is to keep raw journals out of your context. The
  `log-researcher` agent already enforces a distilled output contract — respect it; don't ask it
  to paste full logs back.
- **Verify before you fix.** The findings are the *only* evidence you see, and a haiku summarizer
  can misread. Before proposing any fix, re-check that the cited lines actually support the
  diagnosis (Phase 3). This is where a subtle misread would otherwise propagate into a wrong fix.
- **Reuse the tested engine.** Both you and the researchers reach the VMs only through
  `uv run tools/system_debug.py` — never hand-rolled `ssh`/`journalctl`. It's hermetically tested,
  handles retries/backoff and signature matching, and (being `uv run`) is allowlisted, so parallel
  researchers don't each trigger an `ssh` permission prompt.

## Phase 0 — Preflight

Confirm the cluster exists (`clusters/<name>/main.tf`; folder names use underscores, tolerate a
hyphenated arg). If you can't resolve it, or the cluster isn't up (the sweeper exits **4** /
`hosts` is empty), stop and tell the user — offer `just up <cluster>`. Nothing to triage on a
cluster that was never launched.

## Phase 1 — Triage map (main, background)

Run the sweeper once across **all** roles to see the lay of the land. Run it **in the background**
(Bash tool with `run_in_background: true`) so its retry loop (up to 3 tries, exp backoff, ~≤60s)
doesn't block you; you'll be re-invoked when it finishes.

```bash
uv run tools/system_debug.py <cluster> --json
```

It prints a human report to **stderr** and a JSON summary to **stdout**. Per target the JSON has
`role`, `name`, `ip`, `reachable`, `cloud_init_status`, `failed_units`, `activating_units`,
`signature_hits` (`{source, line}` list), and `healthy`. Exit codes: **0** healthy · **2** issues
· **3** unreachable · **4** usage/not-up.

Read the JSON and build the suspect list: **which roles are not `healthy`, and for each, which
units carry `signature_hits` / appear in `failed_units` / are stuck in `activating_units`.**

- If exit is **0** (every role healthy): report that the cluster is clean and **stop — do not fan
  out**. Spawning researchers against a healthy cluster just burns tokens.
- If **3** (unreachable): the VM(s) may still be booting — say so and offer to re-run.

## Phase 2 — Fan out haiku researchers (parallel)

For each unhealthy role, dispatch a **`log-researcher`** subagent. Send them **in a single
message** (multiple Agent tool calls) so they run concurrently. One role per subagent; if a role
has several suspect units, pass them all to that role's researcher.

Give each a self-contained prompt, e.g.:

> Investigate role **`services`** on cluster **`centralized_pki`**. Suspect units from the triage
> map: **`netbox-stack.service`**, **`otelcol-contrib`**. Run
> `uv run tools/system_debug.py centralized_pki services --unit netbox-stack.service --unit otelcol-contrib --json`
> from the repo root. Apply the triage-patterns. Return only your distilled output contract —
> cited lines with timestamps + a 2–3 sentence hypothesis. Do not paste raw logs.

The researcher returns a compact block (role status, failed/activating units, a handful of cited
lines with timestamps, and a hypothesis). That block — not the raw journal — is what enters your
context.

## Phase 3 — Verify + synthesize (main, opus)

Before proposing anything: **re-read the exact lines each researcher cited and confirm they
actually support the stated cause.** If a citation is thin or the hypothesis over-reaches, pull
the specific unit's journal yourself (`uv run tools/system_debug.py <cluster> <role> --unit <svc>
--json`, or `just ssh <cluster> <role>` then `sudo journalctl -u <svc> -b -e`) rather than
trusting the summary.

Then state the root cause in **plain terms** (not just the log line), citing the exact evidence.
Correlate across roles/units where relevant (e.g. a consumer's `no route to host` lining up with
the DNS hub still coming up). Lean on the `triage-patterns` skill and the worked examples in
`.claude/commands/system-debug.md` for the known causes (otelcol env-file / `adm`, stuck oneshots,
DNS races, image-pull failures). If nothing is conclusive, say so and point at the sweeper's
`↳ dig deeper` hint rather than inventing a cause.

**Special case — a role stuck `cloud-init: running` with NO failed units and NO signature hits.**
The sweeper will call it un-healthy (cloud-init not `done`) but surface nothing, and researchers
can't ssh to dig. This is almost always the **silent wait-loop** pattern (`triage-patterns`
Example 4b): the main runcmd lost a DNS race on an early one-shot install and is now spinning in a
later `until … sleep` loop forever. Confirm it yourself over ssh (`just ssh <cluster> <role>`):
  1. `cloud-init status --long` → `running` + `extended_status: degraded`.
  2. `ps -o pid,ppid,args -ax | grep -E 'runcmd|sleep'` → the `/bin/sh …/scripts/runcmd` process is
     alive with a child `sleep` (the main runcmd is looping, not a background oneshot).
  3. `sudo sed -n '/until/p' /var/lib/cloud/instance/scripts/runcmd` → what it waits for.
  4. `sudo grep -nE 'Could not resolve|not found|<installer>' /var/log/cloud-init-output.log` → the
     earlier step that actually failed (the loop's condition depends on it).
Fix = a resolver-ready gate (`until getent hosts <host>; do sleep 2; done`) + retry around that
installer; live-repair by running the missed install so the loop's condition finally holds.

## Phase 4 — Remediate (plan mode, opus)

Author fixes as the opus main agent, and **enter plan mode / use AskUserQuestion before changing
anything** — the research is done cheaply on haiku, but the fix is where judgment matters. Confirm
scope:

- **Report only** — stop here; the user drives the fix.
- **Apply a safe live fix over SSH now** — patch the file under `/opt/...` or
  `/usr/local/sbin/<svc>.sh` and `sudo systemctl restart --no-block <svc>` (the repo's fast
  live-iteration loop; reach the VM via `just ssh <cluster> <role>`). Then re-verify.
- **Fix and fold back into the `.tftpl`, then recreate** — apply the live fix, port it into the
  cluster's `cloud-init/*.tftpl`, and `just recreate <cluster>` (cloud-init changes need a
  recreate, not a plain `just up`).

Only act after the user chooses. After any fix, **verify by re-running Phase 1** and confirming the
sweeper exits **0** (or that the specific signature is gone) — evidence before claiming it's
fixed.

## Relationship to `/system-debug`

`/system-debug` is the quick single-shot sweep (one process, sequential over roles, output lands
in your context). `triage-logs` is its parallel sibling: use it when a cluster has several roles
or several suspect units and you want the digging isolated in subagent contexts. Both share the
same engine (`tools/system_debug.py`) and the same remediation menu, so findings translate 1:1.
