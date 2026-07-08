#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "typer>=0.12",
#     "rich>=13",
#     "cryptography>=42",
# ]
# ///
"""macos_trust — trust the lab's internal root CA on this macOS host.

Chrome & Safari read the macOS keychain; Firefox keeps its OWN NSS trust store. So a green lock
everywhere needs BOTH: `security add-trusted-cert` (keychain) AND `certutil -A` per Firefox profile
(needs `nss`: `brew install nss`). This CLI does both, from the internal root resolved as:

  --ca-cert PATH  >  the pinned clusters/centralized_pki/.ca/root_ca.crt  >  fetched from step-ca's
  /roots.pem (TOFU, over the CA's :9000).

Because it mutates the host trust store, `install`/`remove` PRINT what they will run and prompt
(unless --yes); `--dry-run` prints and does nothing. See specs/internal-ca.md.

    uv run macos_trust_cli.py install            # keychain + every Firefox profile (prompts)
    uv run macos_trust_cli.py install --dry-run  # just show the commands
    uv run macos_trust_cli.py check auth.lab.theblacktonystark.com   # does the OS trust the leaf?
    uv run macos_trust_cli.py remove
"""

from __future__ import annotations

import shlex
import ssl
import subprocess
import tempfile
import urllib.request
from dataclasses import dataclass
from pathlib import Path

import _pki_common as pc
import typer
from rich.console import Console

app = typer.Typer(add_completion=False, no_args_is_help=True, help=__doc__)
console = Console()

CERT_NICK = "lab internal CA"
DEFAULT_KEYCHAIN = "/Library/Keychains/System.keychain"
DEFAULT_FIREFOX_DIR = str(Path.home() / "Library/Application Support/Firefox/Profiles")
# scripts/macos_trust_cli.py -> clusters/centralized_pki/.ca/root_ca.crt
PINNED_ROOT = pc.CLUSTERS_ROOT / "centralized_pki" / ".ca" / "root_ca.crt"


@dataclass
class Options:
    cluster: str
    ca_cert: str | None
    keychain: str
    firefox_dir: str
    dry_run: bool
    yes: bool
    timeout: float


@app.callback()
def _main(
    ctx: typer.Context,
    cluster: str = typer.Option("centralized_pki", "--cluster"),
    ca_cert: str = typer.Option(
        None, "--ca-cert", help="Root PEM to trust (skips pinned/step-ca resolution)."
    ),
    keychain: str = typer.Option(
        DEFAULT_KEYCHAIN,
        "--keychain",
        help="Keychain to add the root to (Chrome/Safari).",
    ),
    firefox_dir: str = typer.Option(
        DEFAULT_FIREFOX_DIR, "--firefox-dir", help="Firefox Profiles dir (NSS stores)."
    ),
    dry_run: bool = typer.Option(
        False, "--dry-run", help="Print the commands without running them."
    ),
    yes: bool = typer.Option(
        False, "--yes", "-y", help="Do not prompt before mutating the trust store."
    ),
    timeout: float = typer.Option(10.0, "--timeout"),
):
    """macOS internal-CA trust helper."""
    ctx.obj = Options(cluster, ca_cert, keychain, firefox_dir, dry_run, yes, timeout)


def _die(msg: str, code: int = 1):
    console.print(f"[red]error:[/red] {msg}")
    raise typer.Exit(code)


def _resolve_root_pem(o: Options) -> str:
    """Return the internal root CA PEM: --ca-cert > pinned file > step-ca /roots.pem."""
    if o.ca_cert:
        return Path(o.ca_cert).read_text()
    if PINNED_ROOT.exists():
        return PINNED_ROOT.read_text()
    try:
        target = pc.resolve_target(role="ca", port=9000, cluster=o.cluster)
        sslctx = ssl._create_unverified_context()
        with urllib.request.urlopen(
            f"{target.base_url}/roots.pem", timeout=o.timeout, context=sslctx
        ) as resp:
            return resp.read().decode()
    except Exception as exc:  # noqa: BLE001
        _die(
            f"could not resolve the internal root (pass --ca-cert): {exc}",
            code=pc.CHECK_FAIL_EXIT,
        )


def _cert_cn(pem: str) -> str:
    from cryptography import x509
    from cryptography.x509.oid import NameOID

    cert = x509.load_pem_x509_certificate(pem.encode())
    attrs = cert.subject.get_attributes_for_oid(NameOID.COMMON_NAME)
    return attrs[0].value if attrs else CERT_NICK


def _firefox_profiles(firefox_dir: str) -> list[Path]:
    """Every Firefox profile dir (an NSS store lives in each). Empty if Firefox isn't installed."""
    base = Path(firefox_dir)
    if not base.is_dir():
        return []
    return sorted(p for p in base.iterdir() if p.is_dir())


def _commands(o: Options, pem_path: str, cn: str, *, action: str) -> list[list[str]]:
    """Build the keychain + per-Firefox-profile commands for install/remove."""
    cmds: list[list[str]] = []
    if action == "install":
        cmds.append(
            [
                "sudo",
                "security",
                "add-trusted-cert",
                "-d",
                "-r",
                "trustRoot",
                "-k",
                o.keychain,
                pem_path,
            ]
        )
    else:
        cmds.append(["sudo", "security", "delete-certificate", "-c", cn, o.keychain])
    for prof in _firefox_profiles(o.firefox_dir):
        if action == "install":
            cmds.append(
                [
                    "certutil",
                    "-A",
                    "-n",
                    CERT_NICK,
                    "-t",
                    "C,,",
                    "-d",
                    f"sql:{prof}",
                    "-i",
                    pem_path,
                ]
            )
        else:
            cmds.append(["certutil", "-D", "-n", CERT_NICK, "-d", f"sql:{prof}"])
    return cmds


def _run_commands(o: Options, cmds: list[list[str]]) -> int:
    report = pc.CheckReport()
    for cmd in cmds:
        proc = subprocess.run(cmd, capture_output=True, text=True)
        label = " ".join(cmd[:4])
        report.add(label, proc.returncode == 0, (proc.stderr or proc.stdout).strip())
    _render(o, report)
    return report.exit_code


def _render(o: Options, report: pc.CheckReport) -> None:
    from rich.table import Table

    if getattr(o, "_json", False):
        pc.print_json(report.to_dict())
        return
    table = Table("step", "status", "detail", title="macos trust")
    colors = {"pass": "green", "fail": "red", "skip": "yellow"}
    for c in report.checks:
        table.add_row(c.name, f"[{colors[c.status]}]{c.status}[/]", c.detail)
    console.print(table)


def _install_or_remove(o: Options, action: str) -> None:
    pem = _resolve_root_pem(o)
    cn = _cert_cn(pem)
    tmp = tempfile.NamedTemporaryFile("w", suffix=".crt", delete=False)
    tmp.write(pem)
    tmp.close()
    cmds = _commands(o, tmp.name, cn, action=action)

    console.print(
        f"[bold]{action}[/bold] internal root [cyan]{cn!r}[/cyan] — will run:"
    )
    for cmd in cmds:
        # soft_wrap so long temp/keychain paths are printed on one line (copy-pasteable).
        console.print(f"  [dim]$[/dim] {shlex.join(cmd)}", soft_wrap=True)
    ff = _firefox_profiles(o.firefox_dir)
    if not ff:
        console.print(
            "  [yellow]note:[/yellow] no Firefox profiles found — keychain only (install `nss` for Firefox)."
        )

    if o.dry_run:
        console.print("[yellow]dry-run — nothing executed.[/yellow]")
        raise typer.Exit(0)
    if not o.yes and not typer.confirm(
        f"Proceed to {action} the internal root in the host trust store?"
    ):
        _die("aborted by user", code=1)
    raise typer.Exit(_run_commands(o, cmds))


@app.command()
def install(ctx: typer.Context):
    """Add the internal root to the macOS keychain + every Firefox profile."""
    _install_or_remove(ctx.obj, "install")


@app.command()
def remove(ctx: typer.Context):
    """Remove the internal root from the macOS keychain + every Firefox profile."""
    _install_or_remove(ctx.obj, "remove")


@app.command()
def check(
    ctx: typer.Context,
    host: str = typer.Argument(...),
    port: int = typer.Option(443, "--port"),
    sni: str = typer.Option(
        None,
        "--sni",
        help="server name to present (connect by IP, match this hostname)",
    ),
):
    """Verify the leaf served at host:port validates against the macOS system trust; exit nonzero if not."""
    o: Options = ctx.obj
    report = pc.CheckReport()
    sslctx = ssl.create_default_context()  # macOS system trust
    sslctx.check_hostname = sni is not None
    import socket

    try:
        with socket.create_connection((host, port), timeout=o.timeout) as sock:
            with sslctx.wrap_socket(sock, server_hostname=sni or host):
                report.add("OS trusts served leaf", True, f"{host}:{port}")
    except ssl.SSLCertVerificationError as exc:
        report.add(
            "OS trusts served leaf",
            False,
            f"verify failed: {exc.verify_message or exc}",
        )
    except (ssl.SSLError, OSError) as exc:
        report.add("OS trusts served leaf", False, f"connection error: {exc}")
    _render(o, report)
    raise typer.Exit(report.exit_code)


if __name__ == "__main__":
    app()
