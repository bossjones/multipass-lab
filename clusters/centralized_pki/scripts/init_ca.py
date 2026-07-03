#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "typer>=0.12",
#     "rich>=13",
# ]
# ///
"""init_ca — generate a PERSISTENT internal root + intermediate CA for centralized_pki.

By default step-ca generates its root at first boot inside an ephemeral Docker volume, so the
root changes on every `just recreate centralized_pki` — breaking every VM's (and macOS's) trust.
This script generates the root + intermediate ONCE (offline, via the smallstep step-cli image),
so the root becomes a pinned, apply-time-known value that survives rebuilds. See specs/internal-ca.md.

It writes:
  * <out-dir>/{root_ca.crt,root_ca_key,intermediate_ca.crt,intermediate_ca_key}  (the raw material;
    root_ca_key stays here and is NEVER shipped to a VM — step-ca only needs the intermediate key
    at runtime), and
  * <cluster>/ca-material.auto.tfvars  — root_ca_cert / intermediate_ca_cert / intermediate_ca_key
    as heredocs. OpenTofu auto-loads *.auto.tfvars; this file is gitignored (sensitive).

The keys are encrypted with the same password centralized_pki already uses for step-ca
(var.stepca_ca_password); step-ca decrypts the intermediate key with it at runtime.

    uv run init_ca.py generate                 # dev password, default paths
    uv run init_ca.py generate --password '...' # non-throwaway
"""

from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path

import typer
from rich.console import Console

# scripts/init_ca.py -> clusters/centralized_pki/
CLUSTER_DIR = Path(__file__).resolve().parents[1]
STEP_CLI_IMAGE = "smallstep/step-cli:0.28.2"
# Dev default mirrors var.stepca_ca_password in variables.tf so `just up` stays turnkey.
DEV_PASSWORD = "changeit-dev-pki-only"

app = typer.Typer(add_completion=False, no_args_is_help=True, help=__doc__)
console = Console()


@app.callback()
def _main():
    """Persistent internal-CA generator (keeps `generate` as an explicit subcommand)."""


def _die(msg: str, code: int = 1):
    console.print(f"[red]error:[/red] {msg}")
    raise typer.Exit(code)


def _step(tmp: Path, *args: str) -> None:
    """Run `step ...` inside the step-cli container with <tmp> mounted at /work."""
    cmd = [
        "docker",
        "run",
        "--rm",
        "-v",
        f"{tmp}:/work",
        "-w",
        "/work",
        STEP_CLI_IMAGE,
        "step",
        *args,
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        _die(f"step {' '.join(args)} failed:\n{proc.stderr.strip()}")


def _tfvars_heredoc(name: str, pem: str) -> str:
    # Trailing newline inside the heredoc is preserved by OpenTofu; PEM files carry one.
    body = pem if pem.endswith("\n") else pem + "\n"
    return f"{name} = <<-EOT\n{body}EOT\n"


@app.command()
def generate(
    password: str = typer.Option(
        DEV_PASSWORD,
        "--password",
        help="Password protecting the CA keys (must match var.stepca_ca_password).",
    ),
    ca_name: str = typer.Option(
        "centralized-pki-ca",
        "--ca-name",
        help="Common-name prefix for the root/intermediate.",
    ),
    out_dir: Path = typer.Option(
        CLUSTER_DIR / ".ca",
        "--out-dir",
        help="Where to keep the raw material (incl. the offline root key).",
    ),
    tfvars: Path = typer.Option(
        CLUSTER_DIR / "ca-material.auto.tfvars",
        "--tfvars",
        help="tfvars file to (over)write with the pinned material.",
    ),
    force: bool = typer.Option(
        False, "--force", help="Overwrite existing material/tfvars."
    ),
):
    """Generate root + intermediate and pin them into ca-material.auto.tfvars."""
    if shutil.which("docker") is None:
        _die(
            "docker not found — this script runs step-cli via docker to generate the CA."
        )
    if tfvars.exists() and not force:
        _die(
            f"{tfvars} already exists — rerun with --force to regenerate (this rotates the root!)."
        )

    out_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        (tmp / "pw").write_text(password)
        # Root CA (self-signed).
        _step(
            tmp,
            "certificate",
            "create",
            f"{ca_name} Root CA",
            "root_ca.crt",
            "root_ca_key",
            "--profile",
            "root-ca",
            "--password-file",
            "pw",
            "--not-after",
            "87600h",
        )
        # Intermediate CA, signed by the root — this is what step-ca signs leaves with.
        _step(
            tmp,
            "certificate",
            "create",
            f"{ca_name} Intermediate CA",
            "intermediate_ca.crt",
            "intermediate_ca_key",
            "--profile",
            "intermediate-ca",
            "--ca",
            "root_ca.crt",
            "--ca-key",
            "root_ca_key",
            "--ca-password-file",
            "pw",
            "--password-file",
            "pw",
            "--not-after",
            "43800h",
        )
        for f in (
            "root_ca.crt",
            "root_ca_key",
            "intermediate_ca.crt",
            "intermediate_ca_key",
        ):
            shutil.copyfile(tmp / f, out_dir / f)

    root_crt = (out_dir / "root_ca.crt").read_text()
    inter_crt = (out_dir / "intermediate_ca.crt").read_text()
    inter_key = (out_dir / "intermediate_ca_key").read_text()

    tfvars.write_text(
        "# GENERATED by scripts/init_ca.py — pinned internal-CA material (gitignored, sensitive).\n"
        "# The intermediate key is encrypted with var.stepca_ca_password. Regenerate with --force.\n\n"
        + _tfvars_heredoc("root_ca_cert", root_crt)
        + "\n"
        + _tfvars_heredoc("intermediate_ca_cert", inter_crt)
        + "\n"
        + _tfvars_heredoc("intermediate_ca_key", inter_key)
    )

    console.print(
        f"[green]✓[/green] wrote material to [bold]{out_dir}[/bold] (keep root_ca_key OFFLINE)"
    )
    console.print(f"[green]✓[/green] wrote pinned vars to [bold]{tfvars}[/bold]")
    console.print(
        "\nNext: [bold]just recreate centralized_pki[/bold] (bakes the pinned root into step-ca), "
        "then [bold]just up-connected[/bold] to distribute trust fleet-wide."
    )


if __name__ == "__main__":
    app()
