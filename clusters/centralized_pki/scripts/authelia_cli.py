#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "typer>=0.12",
#     "rich>=13",
#     "httpx>=0.27",
# ]
# ///
"""authelia_cli — verify & introspect the cluster's Authelia over its HTTP API.

Reaches Authelia through Traefik at the services VM's IP with a Host: auth.<domain> header
(so no laptop-side DNS is needed); TLS verification defaults OFF since Traefik serves a
step-ca / LE-staging cert. `check` asserts Authelia is up and its forward-auth endpoint is
enforcing (401, not 404). Resolves the server from `tofu output` (or `--server-url`).
See specs/cli-authelia.md.

    uv run authelia_cli.py check --cluster centralized_pki
    uv run authelia_cli.py health --json
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
    domain: str
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
    """Authelia verification CLI."""
    ctx.obj = Options(cluster, server_url, as_json, timeout, insecure)


def resolve(opts: Options) -> Ctx:
    target = pc.resolve_target(
        role="services",
        port=PORT,
        cluster=opts.cluster,
        server_url=opts.server_url,
        url_env="AUTHELIA_URL",
    )
    host_header = f"auth.{target.domain}" if target.domain else None
    return Ctx(
        base_url=target.base_url,
        host_header=host_header,
        domain=target.domain,
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
    if isinstance(data, dict):
        table = Table("field", "value", title=title)
        for key, value in data.items():
            table.add_row(str(key), str(value))
        console.print(table)
    else:
        console.print(str(data))


def _json_or_text(resp):
    try:
        return resp.json()
    except Exception:  # noqa: BLE001 - non-JSON body
        return {"status_code": resp.status_code, "text": resp.text}


# --- introspection commands --------------------------------------------------


@app.command()
def health(ctx: typer.Context):
    """Liveness probe (GET /api/health)."""
    c = resolve(ctx.obj)
    import httpx

    try:
        with c.client() as client:
            resp = client.get("/api/health")
            resp.raise_for_status()
            data = _json_or_text(resp)
    except httpx.HTTPError as exc:
        _die(f"authelia unreachable: {exc}")
    _emit(c, data, title="authelia health")


# --- check -------------------------------------------------------------------


@app.command()
def check(ctx: typer.Context):
    """Assert Authelia is up + its forward-auth endpoint enforces; exit nonzero on failure."""
    c = resolve(ctx.obj)
    import httpx

    report = pc.CheckReport()

    # 1. Health.
    try:
        with c.client() as client:
            resp = client.get("/api/health")
            report.add("authelia health", resp.status_code < 400, f"status={resp.status_code}")
    except httpx.HTTPError as exc:
        report.add("authelia health", False, str(exc))
        _render_check(c, report)
        raise typer.Exit(report.exit_code)

    # 2. Forward-auth enforces end to end: an unauthenticated GET to a protected route
    #    (vault.<domain>/admin) redirects to the Authelia portal. We exercise the REAL middleware
    #    chain rather than calling /api/authz/forward-auth directly — Traefik strips client-supplied
    #    X-Forwarded-* headers, so Authelia can't be driven that way from outside.
    protected_host = f"vault.{c.domain}" if c.domain else None
    try:
        with c.client() as client:
            headers = {"Host": protected_host} if protected_host else None
            resp = client.get("/admin", headers=headers)
        loc = resp.headers.get("location", "")
        redirected = 300 <= resp.status_code < 400 and "auth." in loc
        report.add(
            "forward-auth enforcing",
            redirected,
            f"status={resp.status_code} -> {loc[:60] or '(no redirect)'}",
        )
    except httpx.HTTPError as exc:
        report.add("forward-auth enforcing", False, str(exc))

    _render_check(c, report)
    raise typer.Exit(report.exit_code)


def _render_check(c: Ctx, report: pc.CheckReport):
    if c.as_json:
        pc.print_json(report.to_dict())
        return
    table = Table("check", "status", "detail", title="authelia check")
    colors = {"pass": "green", "fail": "red", "skip": "yellow"}
    for chk in report.checks:
        color = colors[chk.status]
        table.add_row(chk.name, f"[{color}]{chk.status}[/{color}]", chk.detail)
    console.print(table)
    verdict = "PASS" if report.passed else "FAIL"
    console.print(f"[{'green' if report.passed else 'red'}]{verdict}[/]")


if __name__ == "__main__":
    app()
