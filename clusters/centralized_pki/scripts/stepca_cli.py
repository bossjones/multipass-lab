#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "typer>=0.12",
#     "rich>=13",
#     "httpx>=0.27",
# ]
# ///
"""stepca_cli — verify & introspect the cluster's step-ca over its HTTP API.

step-ca ships no read SDK, so this talks to its API directly with httpx. Introspection
(rich tables or `--json`) plus a CI-friendly `check` that asserts the CA is healthy, an
ACME provisioner exists, and a root cert is served — exiting nonzero on failure. Resolves
the server from `tofu output` (or `--server-url`). See specs/cli-stepca.md.

step-ca serves a self-signed leaf on :9000, so verification defaults to OFF (--insecure);
pass --ca-cert /path/to/root_ca.crt to verify strictly. The real chain assertion (a served
leaf chains to the CA root) lives in tls_cli.py.

    uv run stepca_cli.py check --cluster centralized_pki
    uv run stepca_cli.py provisioners --json
"""

from __future__ import annotations

from dataclasses import dataclass

import _pki_common as pc
import typer
from rich.console import Console
from rich.table import Table

PORT = 9000

app = typer.Typer(add_completion=False, no_args_is_help=True, help=__doc__)
console = Console()


@dataclass
class Options:
    cluster: str
    server_url: str | None
    ca_cert: str | None
    as_json: bool
    timeout: float
    insecure: bool


@dataclass
class Ctx:
    base_url: str
    ca_cert: str | None
    as_json: bool
    timeout: float
    insecure: bool

    def client(self):
        import httpx

        verify = self.ca_cert if self.ca_cert else (not self.insecure)
        return httpx.Client(base_url=self.base_url, timeout=self.timeout, verify=verify)


@app.callback()
def _main(
    ctx: typer.Context,
    cluster: str = typer.Option("centralized_pki", "--cluster"),
    server_url: str = typer.Option(None, "--server-url", help="override; else tofu"),
    ca_cert: str = typer.Option(None, "--ca-cert", help="verify TLS against this root PEM"),
    as_json: bool = typer.Option(False, "--json", help="machine-readable JSON output"),
    timeout: float = typer.Option(10.0, "--timeout"),
    insecure: bool = typer.Option(True, "--insecure/--secure", help="skip TLS verification (default: on — step-ca is self-signed)"),
):
    """step-ca verification CLI."""
    ctx.obj = Options(cluster, server_url, ca_cert, as_json, timeout, insecure)


def resolve(opts: Options) -> Ctx:
    target = pc.resolve_target(
        role="ca",
        port=PORT,
        cluster=opts.cluster,
        server_url=opts.server_url,
        url_env="STEPCA_URL",
    )
    return Ctx(
        base_url=target.base_url,
        ca_cert=opts.ca_cert,
        as_json=opts.as_json,
        timeout=opts.timeout,
        insecure=opts.insecure,
    )


def _die(msg: str, code: int = 1):
    console.print(f"[red]error:[/red] {msg}")
    raise typer.Exit(code)


def _emit(c: Ctx, data, title: str | None = None):
    if c.as_json:
        pc.print_json(data)
        return
    if isinstance(data, list) and data and isinstance(data[0], dict):
        cols = list(data[0].keys())
        table = Table(*cols, title=title)
        for row in data:
            table.add_row(*[str(row.get(col, "")) for col in cols])
        console.print(table)
    elif isinstance(data, dict):
        table = Table("field", "value", title=title)
        for key, value in data.items():
            table.add_row(str(key), str(value))
        console.print(table)
    else:
        console.print(str(data))


# --- introspection commands --------------------------------------------------


@app.command()
def health(ctx: typer.Context):
    """CA liveness (GET /health -> {"status":"ok"})."""
    c = resolve(ctx.obj)
    import httpx

    try:
        with c.client() as client:
            resp = client.get("/health")
            resp.raise_for_status()
            data = resp.json()
    except httpx.HTTPError as exc:
        _die(f"step-ca unreachable: {exc}")
    _emit(c, data, title="step-ca health")


@app.command()
def roots(ctx: typer.Context):
    """Fetch the CA root bundle (GET /roots.pem)."""
    c = resolve(ctx.obj)
    import httpx

    try:
        with c.client() as client:
            resp = client.get("/roots.pem")
            resp.raise_for_status()
            body = resp.text
    except httpx.HTTPError as exc:
        _die(f"could not fetch roots: {exc}")
    if c.as_json:
        pc.print_json({"roots_pem": body, "count": body.count("BEGIN CERTIFICATE")})
    else:
        console.print(body)


@app.command()
def provisioners(ctx: typer.Context):
    """List configured provisioners (GET /provisioners)."""
    c = resolve(ctx.obj)
    import httpx

    try:
        with c.client() as client:
            resp = client.get("/provisioners")
            resp.raise_for_status()
            data = resp.json()
    except httpx.HTTPError as exc:
        _die(f"could not list provisioners: {exc}")
    rows = data.get("provisioners", data) if isinstance(data, dict) else data
    _emit(c, [{"name": p.get("name"), "type": p.get("type")} for p in rows], title="provisioners")


# --- check -------------------------------------------------------------------


@app.command()
def check(ctx: typer.Context):
    """Assert CA health + an ACME provisioner + a served root; exit nonzero on failure."""
    c = resolve(ctx.obj)
    import httpx

    report = pc.CheckReport()

    # 1. Health.
    try:
        with c.client() as client:
            resp = client.get("/health")
            ok = resp.status_code < 400 and (resp.json() or {}).get("status") == "ok"
            report.add("ca health", ok, f"status={resp.status_code}")
    except httpx.HTTPError as exc:
        report.add("ca health", False, str(exc))
        _render_check(c, report)
        raise typer.Exit(report.exit_code)

    # 2. An ACME provisioner is configured.
    try:
        with c.client() as client:
            resp = client.get("/provisioners")
            resp.raise_for_status()
            data = resp.json()
        provs = data.get("provisioners", []) if isinstance(data, dict) else (data or [])
        acme = [p for p in provs if str(p.get("type", "")).lower() == "acme"]
        report.add(
            "acme provisioner",
            bool(acme),
            ", ".join(p.get("name", "?") for p in acme) or "none of type acme",
        )
    except httpx.HTTPError as exc:
        report.add("acme provisioner", False, str(exc))

    # 3. A root cert is served.
    try:
        with c.client() as client:
            resp = client.get("/roots.pem")
            resp.raise_for_status()
            n = resp.text.count("BEGIN CERTIFICATE")
            report.add("root cert served", n >= 1, f"{n} cert(s)")
    except httpx.HTTPError as exc:
        report.add("root cert served", False, str(exc))

    _render_check(c, report)
    raise typer.Exit(report.exit_code)


def _render_check(c: Ctx, report: pc.CheckReport):
    if c.as_json:
        pc.print_json(report.to_dict())
        return
    table = Table("check", "status", "detail", title="step-ca check")
    colors = {"pass": "green", "fail": "red", "skip": "yellow"}
    for chk in report.checks:
        color = colors[chk.status]
        table.add_row(chk.name, f"[{color}]{chk.status}[/{color}]", chk.detail)
    console.print(table)
    verdict = "PASS" if report.passed else "FAIL"
    console.print(f"[{'green' if report.passed else 'red'}]{verdict}[/]")


if __name__ == "__main__":
    app()
