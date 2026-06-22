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
OpenTofu root module, cloud-init templates, and tests. The first is
`clusters/centralized_logging/` (syslog-ng log shipping across three VMs; see
`specs/centralized_logging.md` for the full design). A root `Justfile` orchestrates
every cluster **by folder name** — that name is the only argument the recipes take.

```sh
just check centralized_logging   # hermetic: tofu fmt + validate + test (no VMs)
just up    centralized_logging   # tofu apply -> launches all VMs in one apply
just verify centralized_logging  # live: pytest + testinfra over SSH against running VMs
just down  centralized_logging   # tofu destroy
just status                      # multipass list
just ssh   centralized_logging central   # shell onto the <name>-<role> VM
```

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
