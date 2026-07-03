#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "typer>=0.12",
#     "rich>=13",
# ]
# ///
"""system_debug — fast provisioning-log triage for the Multipass cluster VMs.

SSH into a cluster's VM(s), sweep the journals that matter (cloud-init, otelcol-contrib, any
`--failed` units, a boot-wide `-p err` sweep), and *highlight* the smoking-gun lines — the ones
that are obvious the moment you read them (e.g. otelcol's `open /var/log/syslog: permission
denied`). Because these boot issues flap (a oneshot still `activating`, DNS not up yet, an image
pull mid-flight), it retries up to 3 times with exponential backoff, exiting early once the VM
looks healthy.

Networking is done by shelling out to `ssh`/`tofu` (subprocess) — Python never opens a VM socket —
so this is not hit by the macOS "Local Network" block (errno 65) that afflicts the HTTP CLIs.

    uv run tools/system_debug.py centralized_pki            # sweep every role
    uv run tools/system_debug.py centralized_pki services   # one role
    uv run tools/system_debug.py centralized_logging --unit syslog-ng --json

Exit codes: 0 healthy · 2 issues found · 3 unreachable · 4 usage/resolve error.

The pure parsing/analysis/policy lives in `_system_debug_core.py` (stdlib-only, hermetically
tested in tools/tests/); this file owns the I/O (ssh/tofu subprocess) and the rich rendering.
"""

from __future__ import annotations

import json
import subprocess
import time
from pathlib import Path

import _system_debug_core as core
import typer
from rich.console import Console
from rich.text import Text

# tools/system_debug.py -> repo root -> clusters/
REPO_ROOT = Path(__file__).resolve().parents[1]
CLUSTERS_ROOT = REPO_ROOT / "clusters"

# Reuse the Justfile's SSH knobs verbatim (Justfile:15-16) so behaviour matches `just ssh`.
SSH_OPTS = [
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "LogLevel=ERROR",
    "-o", "ConnectTimeout=8",
    "-o", "BatchMode=yes",
]

MAX_HITS_SHOWN = 14


# --- tofu / ssh I/O ----------------------------------------------------------


def resolve_cluster_dir(cluster: str) -> Path | None:
    """Locate clusters/<cluster>/ (tolerating hyphen/underscore)."""
    for name in (cluster, cluster.replace("-", "_")):
        d = CLUSTERS_ROOT / name
        if (d / "main.tf").is_file():
            return d
    return None


def resolve_hosts(cluster_dir: Path) -> dict[str, dict]:
    """Return the cluster's `hosts` output as {role: {name, ipv4}} via `tofu output`."""
    proc = subprocess.run(
        ["tofu", f"-chdir={cluster_dir}", "output", "-json", "hosts"],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return {}
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return {}


def ssh_collect(ip: str, ssh_key: str, remote_script: str) -> tuple[bool, str, str]:
    """Run the remote script over SSH via `sudo bash -s`. Returns (ok, stdout, error_detail)."""
    cmd = ["ssh", *SSH_OPTS, "-i", ssh_key, f"ubuntu@{ip}", "sudo", "bash", "-s"]
    try:
        proc = subprocess.run(
            cmd, input=remote_script, capture_output=True, text=True, timeout=30
        )
    except subprocess.TimeoutExpired:
        return False, "", "ssh timed out (VM may still be booting)"
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "ssh failed").strip().splitlines()
        return False, proc.stdout, detail[-1] if detail else "ssh failed"
    return True, proc.stdout, ""


# --- rendering ---------------------------------------------------------------


def render_report(
    console: Console, cluster: str, attempts: int, results: list[core.TargetResult]
) -> None:
    console.rule(f"[bold]system-debug {cluster}[/]  ·  {attempts} attempt(s)")
    for r in results:
        head = Text(f"\n{r.role}  ", style="bold")
        head.append(f"{r.name} @ {r.ip}", style="cyan")
        console.print(head)

        if not r.reachable:
            console.print(Text(f"  unreachable: {r.error}", style="yellow"))
            continue

        ci_style = "green" if r.cloud_init_status == "done" else "yellow"
        console.print(Text(f"  cloud-init: {r.cloud_init_status}", style=ci_style))
        if r.failed_units:
            console.print(Text(f"  failed units: {', '.join(r.failed_units)}", style="bold red"))
        if r.activating_units:
            console.print(
                Text(f"  still activating: {', '.join(r.activating_units)}", style="yellow")
            )

        if r.signature_hits:
            console.print(Text(f"  {len(r.signature_hits)} signature hit(s):", style="bold red"))
            for source, line in r.signature_hits[:MAX_HITS_SHOWN]:
                console.print(Text(f"    [{source}] {line}", style="red"))
            if len(r.signature_hits) > MAX_HITS_SHOWN:
                extra = len(r.signature_hits) - MAX_HITS_SHOWN
                console.print(Text(f"    … +{extra} more", style="dim"))
            units = sorted({s for s, _ in r.signature_hits if s != "err-sweep"})
            hint_unit = units[0] if units else "<unit>"
            console.print(
                Text(
                    f"    ↳ dig deeper: just ssh {cluster} {r.role}  then  "
                    f"sudo journalctl -u {hint_unit} -b -e",
                    style="dim",
                )
            )
        elif r.healthy:
            console.print(Text("  healthy — no signatures, cloud-init done", style="green"))

    healthy = sum(r.healthy for r in results)
    console.rule(
        f"[bold]{'PASS' if healthy == len(results) else 'ISSUES'}[/]  "
        f"{healthy}/{len(results)} healthy"
    )


# --- command -----------------------------------------------------------------


def main(
    cluster: str = typer.Argument(..., help="Cluster folder under clusters/ (e.g. centralized_pki)."),
    role: str | None = typer.Argument(None, help="One role; omit to sweep every role."),
    max_tries: int = typer.Option(3, "--max-tries", min=1, help="Max poll attempts."),
    base_delay: float = typer.Option(
        5.0, "--base-delay", help="Backoff base seconds (delay = base*3^(n-1))."
    ),
    unit: list[str] = typer.Option([], "--unit", help="Extra unit(s) to sweep (repeatable)."),
    json_out: bool = typer.Option(False, "--json", help="Emit a JSON summary to stdout."),
    ssh_key: str = typer.Option(
        None,
        "--ssh-key",
        envvar="CLUSTER_SSH_KEY",
        help="SSH private key (default ~/.ssh/id_ed25519).",
    ),
) -> None:
    """Sweep a cluster's provisioning journals and surface the root cause fast."""
    # With --json keep stdout clean for the machine and send the human report to stderr.
    console = Console(stderr=json_out)
    key = ssh_key or str(Path.home() / ".ssh" / "id_ed25519")

    cluster_dir = resolve_cluster_dir(cluster)
    if cluster_dir is None:
        console.print(
            Text(f"unknown cluster '{cluster}' — no clusters/<name>/main.tf", style="bold red")
        )
        raise typer.Exit(core.EXIT_USAGE)

    hosts = resolve_hosts(cluster_dir)
    if not hosts:
        console.print(
            Text(
                f"no `hosts` output for {cluster} — is it up?  try: just up {cluster}\n"
                "(a newly-added output also errors until the next `tofu apply`)",
                style="yellow",
            )
        )
        raise typer.Exit(core.EXIT_USAGE)

    if role is not None:
        if role not in hosts:
            console.print(
                Text(
                    f"unknown role '{role}' — available: {', '.join(sorted(hosts))}",
                    style="bold red",
                )
            )
            raise typer.Exit(core.EXIT_USAGE)
        hosts = {role: hosts[role]}

    remote_script = core.build_remote_script(unit)
    results: list[core.TargetResult] = []
    attempts = 0

    for attempt in range(1, max_tries + 1):
        attempts = attempt
        results = []
        for r, host in hosts.items():
            ok, out, err = ssh_collect(host.get("ipv4", ""), key, remote_script)
            if not ok:
                results.append(
                    core.TargetResult(
                        role=r, name=host.get("name", r), ip=host.get("ipv4", "?"), error=err
                    )
                )
            else:
                results.append(core.analyze(r, host, out))

        if all(res.healthy for res in results):
            break
        if attempt < max_tries:
            delay = core.backoff_delay(attempt, base_delay)
            console.print(
                Text(f"  … issues on attempt {attempt}; retrying in {delay:.0f}s", style="dim")
            )
            time.sleep(delay)

    render_report(console, cluster, attempts, results)

    if json_out:
        print(
            json.dumps(
                {
                    "cluster": cluster,
                    "attempts": attempts,
                    "healthy": all(r.healthy for r in results),
                    "targets": [r.to_json() for r in results],
                },
                indent=2,
            )
        )

    raise typer.Exit(core.choose_exit_code(results))


if __name__ == "__main__":
    typer.run(main)
