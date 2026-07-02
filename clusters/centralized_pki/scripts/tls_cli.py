#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "typer>=0.12",
#     "rich>=13",
#     "cryptography>=42",
# ]
# ///
"""tls_cli — inspect & verify the TLS cert a Traefik-served host presents.

The Python equivalent of the wildcard-cert doc's `openssl s_client | openssl x509` check.
`inspect` dumps the served leaf (CN / issuer / SANs / validity); `check` is the load-bearing
PKI assertion, and is flag-aware:

  * default (internal) mode  -> assert the served leaf CHAINS to step-ca's root,
  * enable_letsencrypt_staging -> assert the leaf's issuer is Let's Encrypt STAGING.

The mode is derived from the cluster's enabled_flags (`tofu output`) unless overridden with
--staging/--internal. In internal mode the root comes from --ca-cert, else it is fetched from
the cluster's step-ca (/roots.pem). See specs/cli-tls.md.

    uv run tls_cli.py inspect vault.lab.theblacktonystark.com
    uv run tls_cli.py check auth.lab.theblacktonystark.com --cluster centralized_pki
"""

from __future__ import annotations

import ssl
import tempfile
from dataclasses import dataclass

import _pki_common as pc
import typer
from rich.console import Console
from rich.table import Table

app = typer.Typer(add_completion=False, no_args_is_help=True, help=__doc__)
console = Console()


@dataclass
class Options:
    cluster: str
    as_json: bool
    timeout: float


@app.callback()
def _main(
    ctx: typer.Context,
    cluster: str = typer.Option("centralized_pki", "--cluster"),
    as_json: bool = typer.Option(False, "--json"),
    timeout: float = typer.Option(10.0, "--timeout"),
):
    """TLS cert verification CLI."""
    ctx.obj = Options(cluster, as_json, timeout)


def _die(msg: str, code: int = 1):
    console.print(f"[red]error:[/red] {msg}")
    raise typer.Exit(code)


def _cert_summary(pem: str) -> dict:
    """Parse a PEM leaf into {subject_cn, issuer_cn, sans, not_before, not_after}."""
    from cryptography import x509
    from cryptography.x509.oid import NameOID

    cert = x509.load_pem_x509_certificate(pem.encode())

    def _cn(name):
        attrs = name.get_attributes_for_oid(NameOID.COMMON_NAME)
        return attrs[0].value if attrs else ""

    try:
        sans = cert.extensions.get_extension_for_class(
            x509.SubjectAlternativeName
        ).value.get_values_for_type(x509.DNSName)
    except x509.ExtensionNotFound:
        sans = []
    return {
        "subject_cn": _cn(cert.subject),
        "issuer_cn": _cn(cert.issuer),
        "sans": sans,
        "not_before": str(cert.not_valid_before_utc),
        "not_after": str(cert.not_valid_after_utc),
    }


def _fetch_summary(host: str, port: int, timeout: float, sni: str | None = None) -> dict:
    try:
        pem = pc.fetch_leaf_cert_pem(host, port, server_hostname=sni, timeout=timeout)
    except (ssl.SSLError, OSError) as exc:
        _die(f"could not fetch cert from {host}:{port}: {exc}")
    return _cert_summary(pem)


def _resolve_root_ca(cluster: str, timeout: float) -> str | None:
    """Fetch step-ca's root from the cluster and stash it in a temp file; return its path."""
    try:
        import urllib.request

        target = pc.resolve_target(role="ca", port=9000, cluster=cluster)
        ctx = ssl._create_unverified_context()
        with urllib.request.urlopen(
            f"{target.base_url}/roots.pem", timeout=timeout, context=ctx
        ) as resp:
            pem = resp.read().decode()
    except Exception:  # noqa: BLE001 - any failure -> caller reports "no root"
        return None
    tmp = tempfile.NamedTemporaryFile("w", suffix=".crt", delete=False)
    tmp.write(pem)
    tmp.close()
    return tmp.name


def _staging_mode(cluster: str, override: bool | None) -> bool:
    if override is not None:
        return override
    try:
        target = pc.resolve_target(role="services", port=443, cluster=cluster)
        return "enable_letsencrypt_staging" in target.enabled_flags
    except Exception:  # noqa: BLE001 - tofu not available -> assume internal mode
        return False


# --- commands ----------------------------------------------------------------


@app.command()
def inspect(
    ctx: typer.Context,
    host: str = typer.Argument(...),
    port: int = typer.Option(443, "--port"),
    sni: str = typer.Option(None, "--sni", help="server name to present (connect by IP, match this hostname)"),
):
    """Dump the served leaf cert (CN / issuer / SANs / validity)."""
    o: Options = ctx.obj
    summary = _fetch_summary(host, port, o.timeout, sni)
    if o.as_json:
        pc.print_json(summary)
        return
    table = Table("field", "value", title=f"cert @ {host}:{port}")
    for key, value in summary.items():
        table.add_row(key, ", ".join(value) if isinstance(value, list) else str(value))
    console.print(table)


@app.command()
def check(
    ctx: typer.Context,
    host: str = typer.Argument(...),
    port: int = typer.Option(443, "--port"),
    sni: str = typer.Option(None, "--sni", help="server name to present (connect by IP, match this hostname)"),
    ca_cert: str = typer.Option(None, "--ca-cert", help="root PEM for internal-mode chain check"),
    staging: bool = typer.Option(None, "--staging/--internal", help="override the mode (default: from enabled_flags)"),
):
    """Assert the served leaf matches the expected issuer/root; exit nonzero on failure."""
    o: Options = ctx.obj
    report = pc.CheckReport()
    is_staging = _staging_mode(o.cluster, staging)

    summary = _fetch_summary(host, port, o.timeout, sni)

    if is_staging:
        issuer = summary["issuer_cn"]
        report.add(
            "issuer is LE staging",
            "STAGING" in issuer.upper(),
            f"issuer={issuer!r}",
        )
    else:
        root = ca_cert or _resolve_root_ca(o.cluster, o.timeout)
        if not root:
            report.add("chains to step-ca root", False, "no root available (pass --ca-cert)")
        else:
            ok, detail = pc.verify_chains_to(host, port, root, server_hostname=sni)
            report.add("chains to step-ca root", ok, f"{detail}; issuer={summary['issuer_cn']!r}")

    _render_check(o, report)
    raise typer.Exit(report.exit_code)


def _render_check(o: Options, report: pc.CheckReport):
    if o.as_json:
        pc.print_json(report.to_dict())
        return
    table = Table("check", "status", "detail", title="tls check")
    colors = {"pass": "green", "fail": "red", "skip": "yellow"}
    for chk in report.checks:
        color = colors[chk.status]
        table.add_row(chk.name, f"[{color}]{chk.status}[/{color}]", chk.detail)
    console.print(table)
    verdict = "PASS" if report.passed else "FAIL"
    console.print(f"[{'green' if report.passed else 'red'}]{verdict}[/]")


if __name__ == "__main__":
    app()
