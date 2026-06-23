# multipass-lab

> Local lab environments for [**Multipass**](https://multipass.run/) to prototype and test
> infrastructure with [**OpenTofu**](https://opentofu.org/) and **Ansible** before promoting it
> to a real target like **Proxmox**.

[![CI](https://github.com/bossjones/multipass-lab/actions/workflows/ci.yml/badge.svg)](.github/workflows/ci.yml)
[![OpenTofu](https://img.shields.io/badge/OpenTofu-%E2%89%A5%201.7-FFDA18?logo=opentofu&logoColor=black)](https://opentofu.org/)
[![Multipass](https://img.shields.io/badge/Multipass-VM%20host-E95420?logo=ubuntu&logoColor=white)](https://multipass.run/)
[![License](https://img.shields.io/badge/license-see%20LICENSE-blue)](LICENSE)

Multipass acts as a cheap, local stand-in for the eventual VM host. New infrastructure is
structured so the **same modules can target Multipass locally and Proxmox later** —
parameterize the provider/connection, not the resources.

---

## Contents

- [Why this exists](#why-this-exists)
- [Labs](#labs)
- [Quickstart](#quickstart)
- [How it works](#how-it-works)
- [Repository layout](#repository-layout)
- [Toolchain](#toolchain)
- [Further reading](#further-reading)

---

## Why this exists

Spinning up VMs on a real hypervisor to test a single cloud-init change is slow and expensive.
Multipass gives you throwaway Ubuntu VMs in seconds on your laptop, so you can iterate on
OpenTofu modules, cloud-init templates, and Ansible playbooks locally — then ship the *same*
modules to Proxmox once they're proven.

Each lab ("cluster") is **vendored to its own folder** under [`clusters/`](clusters/) with its
own OpenTofu root module, cloud-init templates, and tests. A single root
[`Justfile`](Justfile) orchestrates every cluster **by folder name** — that name is the only
argument the recipes take.

## Labs

Each lab is self-contained. Click through to its README for the full design, VM topology, and
lab-specific notes.

| Lab | What it demonstrates | VMs | Docs |
|-----|----------------------|-----|------|
| **centralized_logging** | syslog-ng log shipping across three VMs into one collector (`/var/log/remote/<host>/<prog>.log`), with runtime DHCP-IP injection between peers | 3 | 📖 [README](clusters/centralized_logging/README.md) · 📐 [spec](specs/centralized_logging.md) |

> _New labs land as new `clusters/<name>/` folders. CI auto-discovers them — see
> [How it works](#how-it-works)._

## Quickstart

All recipes take the **cluster folder name** as their only argument. Run from the repo root:

```sh
just check  centralized_logging   # hermetic: tofu fmt + validate + test (no VMs)
just up     centralized_logging   # tofu apply -> launches all VMs in one apply
just verify centralized_logging   # live: pytest + testinfra over SSH against running VMs
just logs   centralized_logging   # list collected log files on the central VM
just down   centralized_logging   # tofu destroy

just status                       # multipass list
just ssh    centralized_logging central   # shell onto the <name>-<role> VM
```

Run a single **hermetic** test from the cluster dir:

```sh
tofu -chdir=clusters/<name> test -test-directory=tests/tofu
```

Run a single **live** test:

```sh
cd clusters/<name>/tests/testinfra && uv run pytest -v -k <name>
```

See all recipes with `just --list`.

## How it works

A few conventions are shared by every lab — mirror them when adding a new one.

### Two-layer test split

| Layer | Location | Cost | What it asserts |
|-------|----------|------|-----------------|
| **Hermetic** | [`tests/tofu/*.tftest.hcl`](clusters/centralized_logging/tests/tofu/) | free, no VMs | sizing + rendered cloud-init via `mock_provider "multipass" {}` and `command = plan` (`just check`) |
| **Live** | [`tests/testinfra/`](clusters/centralized_logging/tests/testinfra/) | needs running VMs | end-to-end behavior over SSH with pytest + testinfra (`just verify`) |

Cheap structural assertions go hermetic; behavioral end-to-end checks go in testinfra.

### Runtime IP injection

Multipass hands out DHCP IPs, so peer IPs can't be hardcoded. OpenTofu creates the "server" VM
first, reads its computed `ipv4`, and renders each client's cloud-init (`templatefile` →
`.rendered/`, written via `local_file`) from that value — the reference creates the dependency
edge. The `hosts` output (`{role: {name, ipv4}}`) is the contract
[`tests/testinfra/conftest.py`](clusters/centralized_logging/tests/testinfra/conftest.py)
consumes to build SSH targets.

### VM naming

Cluster folders may use underscores; Multipass instance names use hyphens. Resources are named
`${var.name_prefix}-<role>` (e.g. `centralized-logging-central`); the Justfile maps
folder → VM name via `replace(CLUSTER, "_", "-")`.

### SSH access

Via a keypair injected through cloud-init (default `~/.ssh/id_ed25519`, override with
`-var ssh_pubkey_path=...` or the `CLUSTER_SSH_KEY` env var). testinfra disables host-key
checking since VMs are recreated on every `just up`.

### Continuous integration

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs **hermetic validation only** —
it mirrors `just check` (`tofu fmt -check` + `validate` + `tofu test` with a mocked provider).
A `discover` job enumerates `clusters/<name>/` folders, so **every new lab gets CI for free**.
The live `just verify` suite needs Multipass/KVM VMs and is intentionally out of scope on
GitHub-hosted runners.

## Repository layout

```
multipass-lab/
├── Justfile                       # orchestrates all clusters by folder name
├── CLAUDE.md                      # guidance for Claude Code in this repo
├── clusters/
│   └── centralized_logging/       # ← a lab (OpenTofu root module + tests)
│       ├── main.tf  outputs.tf  providers.tf  variables.tf  versions.tf
│       ├── cloud-init/            # *.yaml.tftpl templates (re-rendered each apply)
│       ├── tests/tofu/            # hermetic .tftest.hcl
│       ├── tests/testinfra/       # live pytest + testinfra over SSH
│       └── README.md
├── specs/
│   └── centralized_logging.md     # full design doc for the lab
└── .github/workflows/ci.yml       # hermetic CI, auto-discovers clusters
```

Generated/transient paths are gitignored: a cluster's `.terraform/`, `.rendered/`, `tofu`
state, and `logs/`. Don't hand-edit `.rendered/` — it is re-rendered from the `.tftpl`
templates on every apply.

## Toolchain

| Tool | Used for |
|------|----------|
| [`multipass`](https://multipass.run/) | local Ubuntu VM host (Proxmox stand-in) |
| [`tofu`](https://opentofu.org/) (OpenTofu ≥ 1.7) | provision VMs + render cloud-init |
| [`just`](https://github.com/casey/just) | task runner orchestrating clusters by name |
| [`uv`](https://docs.astral.sh/uv/) | Python env for the testinfra verify loop |
| `ansible` | configuration management (where applicable) |

**Providers:** [`larstobi/multipass ~> 1.4`](https://registry.terraform.io/providers/larstobi/multipass)
(public registry) + [`hashicorp/local ~> 2.4`](https://registry.terraform.io/providers/hashicorp/local).
`required_version >= 1.7`. Note `cloudinit_file` takes a **file path**, not inline content.

## Further reading

- 📖 [`clusters/centralized_logging/README.md`](clusters/centralized_logging/README.md) — the first lab
- 📐 [`specs/centralized_logging.md`](specs/centralized_logging.md) — full design of the centralized-logging cluster
- 🤖 [`CLAUDE.md`](CLAUDE.md) — repo conventions and `.claude/` automation guidance
- ⚙️ [`Justfile`](Justfile) — every orchestration recipe
- ✅ [`.github/workflows/ci.yml`](.github/workflows/ci.yml) — hermetic CI pipeline
