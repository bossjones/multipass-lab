#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "typer>=0.12",
#     "rich>=13",
#     "httpx>=0.27",
# ]
# ///
"""vaultwarden_cli — verify & introspect the cluster's Vaultwarden over its HTTP API.

Reaches Vaultwarden through Traefik at the services VM's IP with a Host: vault.<domain> header
(no laptop-side DNS needed); TLS verification defaults OFF (Traefik serves a step-ca / LE-staging
cert). `check` asserts Vaultwarden is alive; `version` is best-effort (skipped on 404 — not all
builds expose it). Resolves the server from `tofu output` (or `--server-url`). See specs/cli-vaultwarden.md.

    uv run vaultwarden_cli.py check --cluster centralized_pki
    uv run vaultwarden_cli.py alive --json
"""

from __future__ import annotations

from dataclasses import dataclass

import _pki_common as pc
import typer
from rich.console import Console
from rich.table import Table

PORT = 443

app = typer.Typer(add_completion=False, no_args_is_help=True, help=__doc__)
console = Console()


@dataclass
class Options:
    cluster: str
    server_url: str | None
    as_json: bool
    timeout: float
    insecure: bool


@dataclass
class Ctx:
    base_url: str
    host_header: str | None
    as_json: bool
    timeout: float
    insecure: bool

    def client(self):
        import httpx

        headers = {"Host": self.host_header} if self.host_header else None
        return httpx.Client(
            base_url=self.base_url,
            timeout=self.timeout,
            verify=not self.insecure,
            headers=headers,
        )


@app.callback()
def _main(
    ctx: typer.Context,
    cluster: str = typer.Option("centralized_pki", "--cluster"),
    server_url: str = typer.Option(None, "--server-url", help="override; else tofu"),
    as_json: bool = typer.Option(False, "--json"),
    timeout: float = typer.Option(10.0, "--timeout"),
    insecure: bool = typer.Option(True, "--insecure/--secure", help="skip TLS verification (default: on)"),
):
    """Vaultwarden verification CLI."""
    ctx.obj = Options(cluster, server_url, as_json, timeout, insecure)


def resolve(opts: Options) -> Ctx:
    target = pc.resolve_target(
        role="services",
        port=PORT,
        cluster=opts.cluster,
        server_url=opts.server_url,
        url_env="VAULTWARDEN_URL",
    )
    host_header = f"vault.{target.domain}" if target.domain else None
    return Ctx(
        base_url=target.base_url,
        host_header=host_header,
        as_json=opts.as_json,
        timeout=opts.timeout,
        insecure=opts.insecure,
    )


def _die(msg: str, code: int = 1):
    console.print(f"[red]error:[/red] {msg}")
    raise typer.Exit(code)


def _json_or_text(resp):
    try:
        return resp.json()
    except Exception:  # noqa: BLE001 - /alive returns a bare timestamp string
        return {"status_code": resp.status_code, "text": resp.text}


# --- introspection commands --------------------------------------------------


@app.command()
def alive(ctx: typer.Context):
    """Liveness probe (GET /alive -> 200 + timestamp)."""
    c = resolve(ctx.obj)
    import httpx

    try:
        with c.client() as client:
            resp = client.get("/alive")
            resp.raise_for_status()
            data = _json_or_text(resp)
    except httpx.HTTPError as exc:
        _die(f"vaultwarden unreachable: {exc}")
    if c.as_json:
        pc.print_json(data)
    else:
        console.print(data)


@app.command()
def version(ctx: typer.Context):
    """Server version (GET /api/version — best effort; some builds 404)."""
    c = resolve(ctx.obj)
    import httpx

    try:
        with c.client() as client:
            resp = client.get("/api/version")
            resp.raise_for_status()
            data = _json_or_text(resp)
    except httpx.HTTPError as exc:
        _die(f"could not read version: {exc}")
    if c.as_json:
        pc.print_json(data)
    else:
        console.print(data)


# --- check -------------------------------------------------------------------


@app.command()
def check(ctx: typer.Context):
    """Assert Vaultwarden is alive (+ report version if available); exit nonzero on failure."""
    c = resolve(ctx.obj)
    import httpx

    report = pc.CheckReport()

    # 1. Liveness.
    try:
        with c.client() as client:
            resp = client.get("/alive")
            report.add("vaultwarden alive", resp.status_code == 200, f"status={resp.status_code}")
    except httpx.HTTPError as exc:
        report.add("vaultwarden alive", False, str(exc))
        _render_check(c, report)
        raise typer.Exit(report.exit_code)

    # 2. Version (informational; skip on 404 since not all builds expose it).
    try:
        with c.client() as client:
            resp = client.get("/api/version")
        if resp.status_code == 404:
            report.skip("version", "endpoint not present")
        else:
            report.add("version", resp.status_code == 200, f"status={resp.status_code}")
    except httpx.HTTPError as exc:
        report.skip("version", str(exc))

    _render_check(c, report)
    raise typer.Exit(report.exit_code)


def _render_check(c: Ctx, report: pc.CheckReport):
    if c.as_json:
        pc.print_json(report.to_dict())
        return
    table = Table("check", "status", "detail", title="vaultwarden check")
    colors = {"pass": "green", "fail": "red", "skip": "yellow"}
    for chk in report.checks:
        color = colors[chk.status]
        table.add_row(chk.name, f"[{color}]{chk.status}[/{color}]", chk.detail)
    console.print(table)
    verdict = "PASS" if report.passed else "FAIL"
    console.print(f"[{'green' if report.passed else 'red'}]{verdict}[/]")


if __name__ == "__main__":
    app()
