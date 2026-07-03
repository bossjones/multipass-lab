# Plan: `just set-dns` — auto-register fleet DNS records into AdGuard (+ fix `up-connected` consumer bring-up)

## Context

`centralized_dns` (AdGuard Home over Unbound) is now the fleet resolver: every VM points
`systemd-resolved` at it at first boot via the `dns_server` opt-in var (`Domains=~.`). But
nothing registers **hostname → IP** records into AdGuard, so today the only way `auth.<domain>` /
`warden.<domain>` / `ca.<domain>` resolve is hand-edited `/etc/hosts` entries (see
`clusters/centralized_pki/USAGE.md:54-56`), and every other cluster is reachable by raw IP only.

The user wants a `just` target that, **after the fleet is up**, registers each cluster's service
hostnames as AdGuard **DNS rewrites** (custom A records) so `grafana.<domain>`, `netbox.<domain>`,
`adguard.<domain>`, etc. resolve fleet-wide. Separately, `just up-connected` currently appears to
**not bring up the consumer clusters** (`centralized_pki`, `centralized_unifi`, `centralized_netbox`)
— only the three hubs — which must be fixed so `set-dns-all` has real VMs to register.

Decisions (from the user):
- **Hostname scheme:** `<service>.<domain>` fleet-wide, using pki's domain `lab.theblacktonystark.com`.
- **Record source:** each cluster declares a `dns_records` tofu output (`{hostname: ipv4}`) — vendored, each cluster owns its naming (mirrors `hosts` / `web_urls`).
- **When it runs:** dead last, only after the whole fleet is finished coming up.
- **Bulk bring-up flags:** `up-all` (and `up-connected`) must enable `enable_coroot=true` (logging) and `enable_discovery=true` (netbox).

## Objective

1. `adguard_cli.py` gains idempotent DNS-rewrite commands (`rewrite-list`, `rewrite-set`,
   `rewrite-delete`, `rewrite-sync`) over AdGuard's `/control/rewrite/*` API.
2. Every cluster exposes a `dns_records` output built from a shared `domain` var.
3. `just set-dns <cluster>` and `just set-dns-all` merge those records and sync them into AdGuard.
4. `just up-connected` is fixed so consumers actually come up, and ends by calling `set-dns-all`.
5. Hermetic tests (CLI + tofu) plus a live `just verify-dns` check.

## Problem Statement

- **No custom-record capability exists.** `clusters/centralized_dns/scripts/adguard_cli.py` is
  read-only (`status`/`stats`/`dns-info`/`filters`/`querylog`/`check`); there is only a `_get`
  helper, no `_post`, and the word "rewrite" appears nowhere. AdGuard's rewrite endpoints
  (`GET /control/rewrite/list`, `POST /control/rewrite/add`, `POST /control/rewrite/delete`,
  body `{"domain","answer"}`) are unused.
- **No fleet hostname convention.** Only `centralized_pki` declares `variable "domain"`
  (`clusters/centralized_pki/variables.tf:13`, default `lab.theblacktonystark.com`) and emits
  real hostnames (`auth./warden./ca.<domain>` in `outputs.tf`). Every other cluster's `web_urls`
  are raw-IP. There is no per-cluster `dns_records` output anywhere.
- **`up-connected` consumers not coming up.** The consumer stage is a glob loop
  (`Justfile` ~lines 158-172) that iterates `clusters/*/`, skips the three hubs, and `just up`s the
  rest. It has **no per-cluster rc tracking and no end-of-run summary** (unlike `up-all` at
  `Justfile:82-93`), so a failing/blocked consumer `just up` is silent. The user observes
  pki/unifi/netbox never come up. Likely causes to confirm: (a) an earlier hub `just up` erroring
  or blocking so the loop is never reached, or (b) each consumer `just up` failing its `tofu apply`
  (note: `centralized_unifi` and `centralized_netbox` don't declare `log_shipping_target` /
  `openobserve_endpoint`, which `up-connected` writes into their `.cross-cluster.auto.tfvars.json`
  — normally a warning, but confirm it isn't erroring here), invisible because the recipe uses
  `set -uo pipefail` (no `-e`) and swallows the result.

## Solution Approach

- **CLI (reuse, don't rebuild auth/resolution):** add a `_post(c, path, json_body)` helper
  mirroring `_get` (`adguard_cli.py:145-156`), and rewrite commands that reuse the existing
  `Ctx.client()` login (`adguard_cli.py:59-78`) and `resolve()` server/cred resolution
  (`adguard_cli.py:97-118` → `_dns_common.resolve_target`, port `3000`). `rewrite-sync` reads a
  `{hostname: answer}` JSON object (from `--file PATH` or `--file -` stdin) and idempotently sets
  each (list → delete any existing rows for that domain → add), so re-running is safe and IP
  churn is handled.
- **Data ownership (vendored):** add `variable "domain"` (default `lab.theblacktonystark.com`) and
  a `dns_records` output to **each** cluster — the same duplication pattern already used for
  `dns_server`. Each cluster builds its own `<service>.${var.domain} = <role>.ipv4` map from its
  own VM IPs, so `set-dns` never hardcodes cross-cluster knowledge.
- **Recipe:** `set-dns-all` iterates `clusters/*/` (same guard as `up-connected`), reads each
  `tofu output -json dns_records` (skipping clusters that aren't up / have no records), merges with
  `jq` into one object, and pipes it to `adguard_cli.py … rewrite-sync --file -`.
- **`up-connected` fix:** make the consumer loop loud and fail-visible (per-cluster rc + summary,
  mirroring `up-all`), diagnose the actual apply failure, then append `set-dns-all` as the final
  step (after the Prometheus hot-push) so DNS is registered only once everything is up.

## Relevant Files

- `clusters/centralized_dns/scripts/adguard_cli.py` — add `_post` + `rewrite-*` commands (reuse `Ctx.client()`, `resolve()`).
- `clusters/centralized_dns/scripts/_dns_common.py` — no change; `resolve_target`/`CheckReport` reused as-is.
- `clusters/centralized_dns/tests/adguard/test_adguard_cli.py` — add hermetic tests for the rewrite commands (mirror the `_login` + `--server-url` + pytest-httpserver pattern).
- `clusters/*/outputs.tf` — add a `dns_records` output to each cluster (dns, logging, monitoring, netbox, pki, unifi).
- `clusters/*/variables.tf` — add `variable "domain"` to every cluster except `centralized_pki` (which already has it).
- `clusters/*/tests/tofu/*.tftest.hcl` — add an assertion that `dns_records` keys contain the expected hostnames (at least monitoring + pki; keys are `var.domain`-derived so they're known under `command = plan` + `mock_provider`).
- `Justfile` — add `set-dns`, `set-dns-all`, `verify-dns` recipes; harden + extend the `up-connected` consumer loop; enable `enable_coroot` (logging) + `enable_discovery` (netbox) in `up-all` and `up-connected`.
- `specs/centralized_dns.md` and `specs/cross-cluster.md` — document the rewrite CLI + `set-dns` step.

### New Files
- None strictly required. (Optional: `clusters/centralized_dns/tests/adguard/` already exists; new tests go in the existing file.)

## Reference: per-cluster `dns_records` (service → role IP)

Built from each cluster's `hosts`/`multipass_instance.*.ipv4`, keyed by `<service>.${var.domain}`:

| Cluster | Records (hostname → role IP) |
|---|---|
| centralized_dns | `adguard`, `dns` → `server` |
| centralized_monitoring | `grafana`, `prometheus`, `alertmanager`, `openobserve`, `uptime` → `server` |
| centralized_logging | `logs-grafana`, `logs-prometheus`, `heimdall` → `docker`; `coroot` → `k0s` (only when `enable_coroot`); `syslog` → `central` |
| centralized_netbox | `netbox` → `server`; `diode` → `server` (only when `enable_discovery`) |
| centralized_pki | `auth`, `warden`, `traefik` → `services`; `ca` → `ca` |
| centralized_unifi | `unifi` → `controller` (or `{}` — no web UI; leave minimal) |

Gate conditional records (`coroot`, `diode`) with the same `enable_*` flag that governs their
install, using `merge(... , var.enable_x ? {...} : {})` (pattern already in `centralized_netbox/outputs.tf:13-24`).

## Step by Step Tasks

IMPORTANT: Execute every step in order, top to bottom.

### 1. Diagnose why `up-connected` skips consumers
- Run `just destroy-all && just init-all` then `just up-connected 2>&1 | tee <scratchpad>/upc.log` (use the session scratchpad, not `/tmp`, per repo rules).
- Confirm whether the `=== up-connected: consumer <c> ===` echoes appear. If they don't, the loop isn't reached → inspect the hub steps (a blocked `just up` cloud-init wait, or a `set -u` unbound-var exit).
- If they do appear, run each consumer standalone to capture the real error: `just up centralized_pki`, `just up centralized_unifi`, `just up centralized_netbox` — read the `tofu apply` output.
- Check the undeclared-var angle: `tofu -chdir=clusters/centralized_unifi apply` with the `.cross-cluster.auto.tfvars.json` present — confirm it's a warning, not an error, in this OpenTofu version.

### 2. Harden the `up-connected` consumer loop
- Add per-cluster rc tracking + an end-of-run summary listing which consumers succeeded/failed (mirror `up-all` at `Justfile:82-93`): `rc=0; … just up "$c" || { echo "FAILED: $c"; rc=1; } … ; exit "$rc"` (but only after the DNS-registration step in Step 8).
- Apply whatever concrete fix Step 1 uncovers (e.g. only write cross-cluster vars a cluster actually declares, or fix a required-var/hang). Keep the change minimal and targeted.

### 2b. Enable `enable_coroot` + `enable_discovery` in bulk bring-up
- Per the user: `up-all` (and `up-connected`, which is what actually brings the fleet up) must bring `centralized_logging` up with `enable_coroot=true` and `centralized_netbox` up with `enable_discovery=true`. Both change cloud-init, so they must be set at first apply — fine here since these recipes run after `destroy-all`.
- Implement by writing the flag into the per-cluster `.auto.tfvars.json` the recipe manages:
  - `up-connected`: add `enable_coroot: true` to the logging hub's `.cross-cluster.auto.tfvars.json` (step 1) and `enable_discovery: true` to `centralized_netbox`'s consumer `.cross-cluster.auto.tfvars.json` (the glob loop's `jq -n …` for that cluster).
  - `up-all`: it's a plain glob calling `just up "$c"`; special-case logging/netbox to first write a small `<cluster>/.flags.auto.tfvars.json` (`{enable_coroot:true}` / `{enable_discovery:true}`) before `just up`. (`.auto.tfvars` outranks `terraform.tfvars`; don't use `TF_VAR_` — it's lower precedence, per CLAUDE.md.)
- Consequence: the conditional `coroot.<domain>` (logging k0s) and `diode.<domain>` (netbox) records in Step 5 will now be present, so `set-dns-all` registers them.

### 3. Add DNS-rewrite commands to `adguard_cli.py`
- Add `_post(c, path, json_body)` mirroring `_get` (open `c.client()`, `client.post(path, json=…)`, `raise_for_status`, `close` in `finally`; on `httpx.HTTPError` call `_die`).
- Add commands:
  - `rewrite-list` → `GET /control/rewrite/list`, emit via `_emit`.
  - `rewrite-add DOMAIN ANSWER` → `POST /control/rewrite/add` body `{"domain","answer"}`.
  - `rewrite-delete DOMAIN ANSWER` → `POST /control/rewrite/delete` body `{"domain","answer"}`.
  - `rewrite-set DOMAIN ANSWER` → idempotent: list, delete every existing row whose `domain==DOMAIN`, then add. Prints old→new when it changed.
  - `rewrite-sync` → read a `{hostname: answer}` JSON object from `--file PATH` (`-` = stdin), call the `rewrite-set` logic per entry; print a summary (added/updated/unchanged). Optional `--prune` (default off) to delete AdGuard rows not in the payload.
- Keep all output `--json`-aware via `_emit` / `dc.print_json`.

### 4. Add `variable "domain"` to every cluster
- Add `variable "domain" { type = string; default = "lab.theblacktonystark.com"; description = "DNS suffix for internal service hostnames registered into centralized_dns AdGuard." }` to each cluster's `variables.tf` except `centralized_pki` (already present). Wording/pattern mirrors the duplicated `dns_server` var.

### 5. Add a `dns_records` output to every cluster
- Add to each `outputs.tf` a `dns_records` output = a `{ "<service>.${var.domain}" = <role>.ipv4 }` map per the reference table above. Gate `coroot`/`diode` with `merge(..., var.enable_x ? {...} : {})`. Description: "hostname → ipv4 A-records to register in centralized_dns AdGuard. Consumed by `just set-dns`."

### 6. Add `set-dns` / `set-dns-all` / `verify-dns` recipes to the `Justfile`
- `set-dns CLUSTER`: `tofu -chdir=clusters/<C> output -json dns_records` → pipe to `uv run clusters/centralized_dns/scripts/adguard_cli.py --cluster centralized_dns rewrite-sync --file -`.
- `set-dns-all`: glob `clusters/*/` (guard on `main.tf`), collect each `dns_records` (`… 2>/dev/null || echo '{}'`), merge with `jq -s 'reduce .[] as $x ({}; . * $x)'` into one object, and pipe once to `… rewrite-sync --file -`. Skips clusters that aren't up (empty output → `{}`).
- `verify-dns`: read the merged `dns_records`, resolve `dns_ip` (`tofu -chdir=clusters/centralized_dns output -raw server_ipv4`), and for each `host → ip` assert `dig +short @$dns_ip host` equals `ip`; nonzero exit on mismatch.

### 7. Add hermetic tests
- CLI (`tests/adguard/test_adguard_cli.py`): stub `POST /control/login` (existing `_login`), `/control/rewrite/list|add|delete`; assert `rewrite-set` deletes-then-adds when a row exists, adds when absent, and `rewrite-sync` on a 2-entry JSON payload issues the right calls (use `CliRunner`, `--server-url`, `--file -` with `input=`).
- tofu (`clusters/{centralized_monitoring,centralized_pki}/tests/tofu/*.tftest.hcl`): `command = plan`, `mock_provider "multipass" {}`; assert `output.dns_records` keys contain e.g. `grafana.lab.theblacktonystark.com` / `warden.lab.theblacktonystark.com`.

### 8. Wire `set-dns-all` as the final `up-connected` step
- After the Prometheus scrape-target hot-push (last step), append `just set-dns-all` so records are registered only once the whole fleet is up. Place it before the final `rc` exit so a set-dns failure is reported too.

### 9. Validate end-to-end
- Run the hermetic suites, then a live `just up-connected` → `just verify-all` → `just verify-dns`, plus `just verify-api centralized_dns` (rewrite commands don't break `check`).

## Testing Strategy

- **Hermetic (no VMs):** pytest-httpserver CLI tests for every rewrite command incl. idempotency and sync; `tofu test` assertions on `dns_records` output keys. Run via `just check <cluster>` and the adguard pytest suite.
- **Live (VMs up):** `just set-dns-all` then `just verify-dns` (dig each record against AdGuard) and spot-check `uv run adguard_cli.py --cluster centralized_dns rewrite-list`. Confirm `auth.<domain>`/`warden.<domain>` now resolve without `/etc/hosts` edits.
- **Edge cases:** cluster not up (empty `dns_records` → skipped, no crash); re-running `set-dns-all` (idempotent, "unchanged"); IP churn after a `recreate` (set overwrites old answer); conditional records absent when `enable_coroot`/`enable_discovery` are off.

## Acceptance Criteria

- `adguard_cli.py rewrite-list|rewrite-set|rewrite-delete|rewrite-sync` work against AdGuard `/control/rewrite/*`; `rewrite-set`/`rewrite-sync` are idempotent.
- Every cluster exposes `dns_records` (built from `var.domain`) and a `domain` var.
- `just set-dns-all` registers all up-cluster records in one call; `just verify-dns` passes (each hostname resolves to the expected IP via AdGuard).
- `just up-connected` brings up **all six** clusters (hubs + pki + unifi + netbox), reports any consumer failure loudly (nonzero exit + summary), and ends by running `set-dns-all`.
- Hermetic CLI + tofu tests pass under `just check` / the adguard pytest suite.

## Validation Commands

- `cd clusters/centralized_dns/tests/adguard && uv run pytest -v` — hermetic rewrite-CLI tests.
- `just check centralized_monitoring` and `just check centralized_pki` — fmt/validate + `dns_records` tofu assertions.
- `uv run clusters/centralized_dns/scripts/adguard_cli.py --help` — new commands listed.
- `ruff check clusters/centralized_dns/scripts/adguard_cli.py` — lint clean.
- Live: `just destroy-all && just init-all && just up-connected` (all 6 up, no silent consumer failure) → `just verify-all` → `just verify-dns` → `uv run clusters/centralized_dns/scripts/adguard_cli.py --cluster centralized_dns rewrite-list`.

## Notes

- No new dependencies — `adguard_cli.py` already declares `typer`/`rich`/`httpx`; `jq`/`dig` are already used across the `Justfile`.
- AdGuard rewrite `answer` is the A-record IP; `add` is additive (allows dupes), so idempotent `set` must delete matching rows first.
- Keep `domain` duplicated per cluster (matching the existing `dns_server` duplication) rather than introducing a root-level shared var — consistent with the repo's per-cluster vendoring.
- The undeclared cross-cluster vars in `centralized_unifi`/`centralized_netbox` are a separate concern (full telemetry wiring); this plan only ensures they **come up**, not that they ship logs/OTLP. Note it for a follow-up if desired.
