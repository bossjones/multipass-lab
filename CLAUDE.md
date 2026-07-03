# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

Lab environments for [Multipass](https://multipass.run/) used to prototype and test
infrastructure with **OpenTofu** and **Ansible** before promoting it to a real target
like Proxmox. Multipass acts as a cheap, local stand-in for the eventual VM host.

Local toolchain: `multipass`, `tofu` (OpenTofu), `just`, `ansible`, and `uv`. Structure
new infrastructure so the same modules can target Multipass locally and Proxmox later
(parameterize the provider/connection, not the resources).

## Clusters

Each cluster is **vendored to its own folder** under `clusters/<name>/` with its own
OpenTofu root module, cloud-init templates, and tests. The clusters are
`clusters/centralized_logging/` (syslog-ng log shipping across three VMs; see
`specs/centralized_logging.md`), `clusters/centralized_monitoring/` (Grafana/Prometheus/
OpenObserve stack), `clusters/centralized_netbox/` (a NetBox DCIM/IPAM server + a test VM
that **self-registers** into it via the REST API on first boot; see `specs/centralized_netbox.md`),
and `clusters/centralized_dns/` (a single VM running **AdGuard Home** (`:53`) over a recursive
**Unbound** (`127.0.0.1:5335`), both host-level under systemd — the network-wide ad-blocking DNS
resolver; see `specs/centralized_dns.md`). `centralized_dns` is a **cross-cluster hub that comes up
FIRST** in `just up-connected`: every other VM points its resolver at AdGuard at first boot (the
`dns_server` opt-in var). A root `Justfile` orchestrates every cluster **by folder name** — that
name is the only argument the recipes take.

```sh
just check centralized_logging   # hermetic: tofu fmt + validate + test (no VMs)
just up    centralized_logging   # tofu apply -> launches all VMs in one apply
just up-connected                # bring the whole fleet up wired for cross-cluster telemetry (see below)
just verify centralized_logging  # live: pytest + testinfra over SSH against running VMs
just verify-connected            # live e2e for the cross-cluster wiring (after up-connected)
just verify-all                  # live: run every cluster's testinfra suite (glob-discovered)
just verify-api centralized_monitoring # live: hit Grafana/Prometheus/OpenObserve HTTP APIs + assert (see below)
just destroy centralized_logging # tofu destroy + prune orphaned VMs (see below)
just recreate centralized_logging # destroy (incl. orphan cleanup) then up
just prune centralized_logging   # delete VMs tofu no longer tracks (recover a failed up)
just down                        # graceful `multipass stop --all` (all VMs, preserved)
just status                      # multipass list
just ssh   centralized_logging central   # shell onto the <name>-<role> VM
just open  centralized_monitoring        # open the core dashboards in Chrome
just open  centralized_monitoring --full # + every enabled /metrics endpoint (debug)
just locust centralized_monitoring       # host-run Locust web UI (localhost:8089) drives live traffic
just locust-check centralized_monitoring # short headless smoke run -> exit code (see below)
just coroot-status centralized_logging   # Coroot stack pods on the k0s node (see below)
just coroot-deploy centralized_logging   # re-run the Coroot installer (idempotent repair)
```

**Cross-cluster telemetry (opt-in).** Any cluster can become a **log-shipper** and a
**scrape-target** for the two hubs. Consumer clusters declare opt-in vars — `log_shipping_target`
(host:port of the `centralized_logging` syslog-ng collector) and `openobserve_endpoint` (host:port
of `centralized_monitoring`'s OpenObserve) — that, when set, render a syslog-ng client drop-in + an
otelcol-contrib agent into every VM's cloud-init. The monitoring hub gains `extra_scrape_targets`
(list of `{job, ip, port}`) templated into `prometheus.yml`. All three share the byte-identical
snippets in `clusters/_shared/cloud-init/` (a **deliberate exception** to per-cluster vendoring; the
`_shared` prefix keeps it out of the `clusters/*/` recipe globs, which skip any dir without a
`main.tf`). Defaults are empty, so a plain `just up <cluster>` stays turnkey and isolated.
`just up-connected` orchestrates the whole fleet: it applies `centralized_logging` and
`centralized_monitoring` first, discovers their IPs, brings up every consumer with both hub IPs
wired in a single boot, then **hot-pushes** the discovered scrape targets into the already-running
Prometheus (scp'd `prometheus.yml` + container restart — the monitoring VM is never recreated, so
the IP consumers push OTLP to never churns). `just verify-connected` is the live e2e. The reference
consumer is `centralized_pki`; full design in `specs/cross-cluster.md`.

**Internal-CA trust (opt-in).** `centralized_pki` (step-ca) is the lab CA. Every cluster accepts an
`internal_ca_cert` var (empty default) that, when set, drops the root into
`/usr/local/share/ca-certificates/` + runs `update-ca-certificates` at first boot — the same gated
`write_files` idiom as `dns_server`. `scripts/init_ca.py generate` **persists** step-ca's
root+intermediate (pinned into a gitignored `ca-material.auto.tfvars`; needs `just recreate
centralized_pki`) so the root survives rebuilds and is static — hence `just up-connected` injects it
fleet-wide with no hub ordering. `just trust-ca <cluster>`/`trust-ca-all` hot-push trust to running
VMs; `just trust-ca-macos` trusts it on the Mac (System keychain + Firefox NSS via `certutil`). Only
`centralized_pki`'s Traefik serves internal-CA TLS today (Phase 2 = other services). Design:
`specs/internal-ca.md`; runbook: `docs/internal-ca-tutorial.md`.

**Coroot (opt-in eBPF observability on k0s).** `enable_coroot` deploys the self-hosted
[Coroot](https://github.com/coroot/coroot) stack (server + eBPF node-agent + cluster-agent +
bundled Prometheus + ClickHouse) onto the `centralized_logging` k0s node via Helm, declaratively
in cloud-init (no cloud account, no secrets; arm64-native). `enable_ingress` adds an ingress-nginx
controller and exposes Coroot's UI through it (also always on a NodePort, `http://<k0s_ip>:30080`).
Both default **off**; enabling Coroot auto-bumps the k0s VM to 4 vCPU / 8G / 50G (`local.k0s_size`
in `main.tf`). Because it lives in cloud-init, enabling it needs `just recreate centralized_logging`
(not `just up`). Full design in `specs/coroot.md`; flag reference in
`clusters/centralized_logging/docs/feature-flags.md`.

A failed `just up` (e.g. a `multipass launch` timeout) leaves an orphaned VM that OpenTofu
never recorded in state, so plain `tofu destroy` can't remove it and the next `up` collides
(`instance already exists`). `just prune` deletes + purges any cluster-prefixed VMs that
`tofu state` no longer tracks (safe anytime — it won't touch a managed VM); `just destroy`
runs it automatically after `tofu destroy`, and `just recreate` chains destroy→up.

**Editing cloud-init requires `just recreate`, not `just up`.** OpenTofu does not recreate a
`multipass_instance` when only the rendered cloud-init (`local_file`) content changes, so a plain
`just up` after editing a `.tftpl` silently reuses the old VM — `just verify` then runs against
**stale** cloud-init (hermetic tests pass, live tests fail confusingly). Use `just recreate <name>`
to redeploy cloud-init to running VMs. (Also note: Multipass injects the **host** timezone into
guests at first boot, overriding a declarative cloud-init `timezone:` — see `specs/ntp.md`.)

`just open` reads the cluster's `web_urls` output (`{core, all}`, both flag-aware) and
opens each URL via `open -a "Google Chrome"` (override with `BROWSER_APP=...`; falls back
to the default browser). No flag opens `core` (human dashboards); `--full`/`--all` opens
`all` (core + every **enabled** exporter endpoint — disabled flags are skipped, not opened).

**Observability verification CLIs.** `centralized_monitoring/scripts/{grafana,prometheus,openobserve}_cli.py`
are uv single-file CLIs (typer + rich) that hit those services' HTTP APIs from the host for
both introspection and a CI-style `check` (exits nonzero on failure). They resolve the server
IP from `tofu output` (or `--server-url`) via the shared `scripts/_obs_common.py`, and share the
repo's two-layer test split: hermetic suites in `tests/{grafana,prometheus,openobserve,obs_common}/`
(pytest-httpserver, no VMs) and live use via `just verify-api` / `just {grafana,prometheus,openobserve}-check`.
Design docs: `specs/cli-grafana.md`, `specs/cli-prometheus.md`, `specs/cli-openobserve.md`. The
query clients are `grafana-client`, `prometheus-api-client`, and raw `httpx` (OpenObserve has no
read SDK) — **not** the ingestion/IaC libraries (`grafana-foundation-sdk`, `client_python`,
`openobserve-python-sdk`), which are reserved for the opt-in e2e inject→query loop.

The `centralized_netbox` cluster follows the same shape: `scripts/netbox_cli.py` (typer + rich +
the official `pynetbox` SDK, plus raw `httpx` for the `/api/status/` probe) with a hermetic suite
in `tests/netbox/` (pytest-httpserver) and live use via `just verify-api` / `just netbox-check`.
`verify-api` auto-discovers each cluster's `scripts/*_cli.py` (skipping `heimdall_cli`, which has
no `check`), so it needs no per-cluster edit. Design docs: `specs/cli-netbox.md`. NetBox auth is a
**pinned lab API token** (`var.netbox_api_token`) the server bootstrap creates via `manage.py` on
first boot, exposed via `tofu output` on purpose (throwaway VMs) — do not copy that to Proxmox. The
cluster pins **NetBox 4.1** (`netbox_docker_ref = 3.0.2`): 4.2+ uses hashed v2/Bearer tokens whose
value can't be pinned. Its cloud-init brings NetBox up **asynchronously** (systemd oneshot,
`--no-block`) because netbox-docker's image pull exceeds Multipass's 300s launch window. On top of
the cluster/site bootstrap, the server also **seeds a base data model** (`netbox-seed.sh`:
organization hierarchy, a DCIM device library, a real Device for the Multipass host, IPAM keyed to
the live subnet, tenancy) so a fresh NetBox is immediately useful — the client is a
`Virtualization` VM (not a DCIM device) that links to the host Device; see `specs/netbox-data.md`.

**Locust load generators.** `centralized_monitoring/scripts/locust_cli.py` (uv single-file, typer +
rich, wrapping `locust`) is a **host-run** load generator — no in-cluster deployment, no `enable_locust`
flag, no cloud-init/compose changes. It resolves VM IPs from `tofu output` (or `--server-url`) via the
same `_obs_common.py`, then drives a cluster's ingest/query surfaces (OpenObserve `:5080` `_json`, OTLP
`:4318`, StatsD `udp:8125`, Prometheus `:9090`, Grafana `:3000`) so dashboards show live traffic.
Recipes: `just locust` (web UI on `localhost:8089`), `just locust-headless` (pass `-u/-r/-t`),
`just locust-check` (CI smoke, exits nonzero), `just locust-targets` (print resolved endpoints, no
load). Hermetic suite in `tests/locust/` (pytest-httpserver + stub UDP socket, no VMs). Design doc:
`specs/locustio.md`.

Run a single hermetic test from the cluster dir:
`tofu -chdir=clusters/<name> test -test-directory=tests/tofu`.
Run a single live test: `cd clusters/<name>/tests/testinfra && uv run pytest -v -k <name>`.

### Architecture conventions (mirror these in new clusters)

- **Two-layer test split.** `tests/tofu/*.tftest.hcl` are *hermetic* — they use
  `mock_provider "multipass" {}` and `command = plan` so they assert on sizing and rendered
  cloud-init **without launching any VM** (`just check`). `tests/testinfra/` are *live* —
  pytest + testinfra connect over SSH to running VMs (`just verify`). Keep new validation in
  the layer that matches its cost: cheap structural assertions go hermetic, behavioral
  end-to-end checks go in testinfra.
- **VM naming.** Cluster folders may use underscores; Multipass instance names use hyphens.
  Resources are named `${var.name_prefix}-<role>` (e.g. `centralized-logging-central`); the
  Justfile maps folder→VM name via `replace(CLUSTER, "_", "-")`.
- **Runtime IP injection.** Multipass hands out DHCP IPs, so peer IPs can't be hardcoded.
  OpenTofu creates the "server" VM first, reads its computed `ipv4`, and renders each client's
  cloud-init (`templatefile` into `.rendered/`, written via `local_file`) from that value —
  the reference creates the dependency edge. The `hosts` output (`{role: {name, ipv4}}`) is
  the contract `tests/testinfra/conftest.py` consumes to build SSH targets.
- **SSH access** is via a keypair injected through cloud-init (default `~/.ssh/id_ed25519`,
  override with `-var ssh_pubkey_path=...` or `CLUSTER_SSH_KEY`). testinfra disables
  host-key checking since VMs are recreated every `just up`.
- **Providers:** `larstobi/multipass ~> 1.4` (public registry) + `hashicorp/local ~> 2.4`;
  `required_version >= 1.7`. `cloudinit_file` takes a **file path**, not inline content.

## `.claude/` Automation

The active machinery here is a Claude Code hook + skill system, not application code:

- **Hooks are uv single-file scripts.** Every hook in `.claude/hooks/` starts with
  `#!/usr/bin/env -S uv run --script` and an inline PEP 723 `# /// script` block
  declaring `requires-python`. Run/test one directly with `uv run .claude/hooks/<name>.py`.
  They are wired into Claude lifecycle events (PreToolUse, PostToolUse, Stop, SessionStart,
  etc.) in `.claude/settings.json`.
- **`pre_tool_use.py` enforces guardrails** — it blocks dangerous `rm` commands and access
  to `.env` files. Expect tool calls touching those to be denied at the hook layer.
- **PostToolUse runs validators** (`skill-edit-review.py`, `version-bump-reviewer.py`) plus
  the validators in `.claude/hooks/validators/` (`ruff_validator.py`, `ty_validator.py`,
  `validate_new_file.py`, `validate_file_contains.py`).
- **Shared utilities** live under `.claude/hooks/utils/` (`llm/` for OpenAI/Anthropic/Ollama
  task summarization, `tts/` for notification audio).
- **Skills** live in `.claude/skills/` (each a `SKILL.md` + supporting docs); custom slash
  commands in `.claude/commands/`; subagents in `.claude/agents/`.
- The status line is `uv run .claude/status_lines/status_line_v10.py` (latest of several
  versioned variants).

## Conventions

- **Python tooling is `uv`-based.** Use `uv run ...` (and `uvx`) rather than a system
  Python or a manually managed venv. Lint with `ruff check`.
- **Secrets** are in `.env` (gitignored, and hook-blocked from reads). `ENGINEER_NAME` and
  the `BOSS_SKILL_ANTHROPIC_API_KEY` used by skill evals/judges live there.
- **Bash commands are routed through `rtk`** (a token-optimizing proxy) via the global hook;
  most commands you write are transparently rewritten (e.g. `git status` → `rtk git status`).
- **Generated/transient paths are gitignored:** a cluster's `.terraform/`, `.rendered/`,
  `tofu` state, and `logs/` are not committed. Don't hand-edit `.rendered/` — it is
  re-rendered from the `.tftpl` templates on every apply.
- `additionalDirectories` in settings grants access to sibling repos `boss-skills` and
  `terraform-provider-multipass`. Note the committed cluster uses the **public**
  `larstobi/multipass` provider; the sibling `terraform-provider-multipass` is a custom
  provider available to exercise but not what `clusters/centralized_logging` wires up today.

## Working fast on live iterations

- **VMs are launchable here; drive them over SSH, not `multipass exec`.** The Justfile note that
  `multipass exec`/`shell` "do not route to the VMs in this environment" is true, but the VMs are
  reachable by IP: `ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 ubuntu@$(tofu
  -chdir=clusters/<name> output -json hosts | jq -r '.<role>.ipv4')`.
- **Override a `terraform.tfvars`-pinned var with `*.auto.tfvars`, NOT `TF_VAR_`.** OpenTofu env
  vars are *lower* precedence than `terraform.tfvars`, so `TF_VAR_enable_x=true just up` is silently
  ignored. Drop a throwaway `clusters/<name>/x.auto.tfvars` (it outranks `terraform.tfvars`); move
  it out when done — `.auto.tfvars` is not gitignored. **Gotcha:** `tofu test` (so `just check`)
  *also* auto-loads `*.auto.tfvars`/`.auto.tfvars.json` from the cluster dir — a generated
  `.cross-cluster.auto.tfvars.json` or a persisted `ca-material.auto.tfvars` then sets opt-in vars
  during hermetic tests and breaks `*_off_by_default` assertions. Pin those vars OFF in each
  `tests/tofu/*.tftest.hcl`'s **file-level** `variables {}` block (it outranks auto-loaded tfvars;
  on-runs override at run level).
- **Iterate on cloud-init without a full `just recreate`.** Provisioning runs async via a systemd
  oneshot (e.g. `netbox-stack.service`) in an idempotent retry loop; when a step blocks it can sit
  `activating` with no new output. SSH in, `sudo journalctl -u <svc>`, patch the `/opt/...` files or
  `/usr/local/sbin/<svc>.sh`, then `sudo systemctl restart --no-block <svc>` — far faster than
  destroy→up. Fold the fix back into the `.tftpl` afterward.
- **The `pre_tool_use` hook matches on substrings**, so it blocks otherwise-fine commands containing
  `rm ` or `.env`: `docker run --rm`, `grep .env`, `rm -f` all get denied. Use `docker run` (+
  `docker container prune -f`), avoid the literal `.env` token, and `mv` to the scratchpad, not `rm`.
- **zsh does not word-split unquoted vars.** `for x in $list` / `$CMD args` run the whole value as a
  single word — inline the list in the `for`, or use an array / `${=var}`.
