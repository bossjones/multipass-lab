#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "typer>=0.12",
#     "rich>=13",
#     "httpx>=0.27",
# ]
# ///
"""adguard_cli — verify & introspect the centralized_dns AdGuard Home over its control API.

Talks to AdGuard Home's /control API with httpx (design ported from the async `adguardctl`
package in adguardhome-unbound-macos-setup/tools). Introspection (rich tables or `--json`) plus
a CI-friendly `check` that asserts AdGuard is running and forwarding to the local Unbound
upstream. Resolves the server from `tofu output` (or `--server-url`). See specs/centralized_dns.md.

    uv run adguard_cli.py check --cluster centralized_dns
    uv run adguard_cli.py status --json
    uv run adguard_cli.py stats
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import NoReturn

import _dns_common as dc
import typer
from rich.console import Console
from rich.table import Table

PORT = 3000
DEFAULT_USER = "admin"
DEFAULT_PASSWORD = "test1234"
UNBOUND_UPSTREAM = "127.0.0.1:5335"

app = typer.Typer(add_completion=False, no_args_is_help=True, help=__doc__)
console = Console()


@dataclass
class Options:
    cluster: str
    server_url: str | None
    user: str | None
    password: str | None
    as_json: bool
    timeout: float


@dataclass
class Ctx:
    base_url: str
    user: str
    password: str
    as_json: bool
    timeout: float

    def client(self):
        """An httpx.Client logged into AdGuard Home (session cookie) against /control."""
        import httpx

        client = httpx.Client(
            base_url=f"{self.base_url}/control",
            timeout=self.timeout,
            follow_redirects=True,
        )
        # AdGuard Home's canonical auth: POST /control/login sets a session cookie. Fall back to
        # HTTP Basic (mirrors adguardctl) if login is unavailable (e.g. auth disabled).
        try:
            resp = client.post(
                "/login", json={"name": self.user, "password": self.password}
            )
            if resp.status_code >= 400:
                client.auth = httpx.BasicAuth(self.user, self.password)
        except httpx.HTTPError:
            client.auth = httpx.BasicAuth(self.user, self.password)
        return client


@app.callback()
def _main(
    ctx: typer.Context,
    cluster: str = typer.Option("centralized_dns", "--cluster"),
    server_url: str = typer.Option(None, "--server-url", help="override; else tofu"),
    user: str = typer.Option(
        None, "--user", help=f"default {DEFAULT_USER} / $ADGUARD_USER"
    ),
    password: str = typer.Option(None, "--password", help="$ADGUARD_PASSWORD"),
    as_json: bool = typer.Option(False, "--json", help="machine-readable JSON output"),
    timeout: float = typer.Option(10.0, "--timeout"),
):
    """AdGuard Home verification CLI."""
    ctx.obj = Options(cluster, server_url, user, password, as_json, timeout)


def resolve(opts: Options) -> Ctx:
    target = dc.resolve_target(
        port=PORT,
        cluster=opts.cluster,
        server_url=opts.server_url,
        url_env="ADGUARD_URL",
    )
    user, password = dc.resolve_credentials(
        opts.user,
        opts.password,
        user_env="ADGUARD_USER",
        pass_env="ADGUARD_PASSWORD",
        default_user=DEFAULT_USER,
        default_password=DEFAULT_PASSWORD,
    )
    return Ctx(
        base_url=target.base_url,
        user=user,
        password=password,
        as_json=opts.as_json,
        timeout=opts.timeout,
    )


def _die(msg: str, code: int = 1) -> NoReturn:
    console.print(f"[red]error:[/red] {msg}")
    raise typer.Exit(code)


def _emit(c: Ctx, data, title: str | None = None):
    if c.as_json:
        dc.print_json(data)
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


def _get(c: Ctx, path: str):
    import httpx

    client = c.client()  # already logged in; do NOT reopen with `with`
    try:
        resp = client.get(path)
        resp.raise_for_status()
        return resp.json()
    except httpx.HTTPError as exc:
        _die(f"GET {path} failed: {exc}")
    finally:
        client.close()


# --- introspection commands --------------------------------------------------


@app.command()
def status(ctx: typer.Context):
    """AdGuard Home status (GET /control/status)."""
    c = resolve(ctx.obj)
    _emit(c, _get(c, "/status"), title="adguard status")


@app.command()
def stats(ctx: typer.Context):
    """Query statistics (GET /control/stats)."""
    c = resolve(ctx.obj)
    data = _get(c, "/stats")
    # Drop the big per-domain arrays for the table view; keep them in --json.
    if not c.as_json and isinstance(data, dict):
        data = {k: v for k, v in data.items() if not isinstance(v, list)}
    _emit(c, data, title="adguard stats")


@app.command(name="dns-info")
def dns_info(ctx: typer.Context):
    """DNS config incl. upstreams (GET /control/dns_info)."""
    c = resolve(ctx.obj)
    data = _get(c, "/dns_info")
    if not c.as_json and isinstance(data, dict):
        data = {k: v for k, v in data.items() if not isinstance(v, (list, dict))} | {
            "upstream_dns": (
                data.get("upstream_dns") if isinstance(data, dict) else None
            ),
        }
    _emit(c, data, title="adguard dns_info")


@app.command()
def filters(ctx: typer.Context):
    """Configured filter lists (GET /control/filtering/status)."""
    c = resolve(ctx.obj)
    data = _get(c, "/filtering/status")
    rows = data.get("filters") if isinstance(data, dict) else data
    _emit(c, rows or [], title="adguard filters")


@app.command()
def querylog(ctx: typer.Context, limit: int = typer.Option(20, "--limit")):
    """Recent query log (GET /control/querylog)."""
    c = resolve(ctx.obj)
    data = _get(c, f"/querylog?limit={limit}")
    rows = data.get("data") if isinstance(data, dict) else data
    _emit(c, rows or [], title="adguard querylog")


# --- check -------------------------------------------------------------------


@app.command()
def check(ctx: typer.Context):
    """Assert AdGuard is running + forwarding to the local Unbound upstream; exit nonzero on failure."""
    c = resolve(ctx.obj)
    import httpx

    report = dc.CheckReport()

    client = c.client()  # already logged in; reused across checks, closed at the end
    try:
        # 1. status reachable + protection running.
        try:
            resp = client.get("/status")
            resp.raise_for_status()
            st = resp.json()
            running = bool(st.get("running") or st.get("protection_enabled"))
            report.add("status reachable", True, f"version={st.get('version', '?')}")
            report.add("running", running, f"running={st.get('running')}")
            dns_addrs = st.get("dns_addresses") or []
            report.add(
                "dns_addresses", len(dns_addrs) >= 1, f"{len(dns_addrs)} addr(s)"
            )
        except httpx.HTTPError as exc:
            report.add("status reachable", False, str(exc))
            _render(c, report)
            raise typer.Exit(report.exit_code)

        # 2. Upstream wired to the local Unbound recursive resolver.
        try:
            resp = client.get("/dns_info")
            resp.raise_for_status()
            info = resp.json()
            upstreams = info.get("upstream_dns") or []
            wired = any(UNBOUND_UPSTREAM in str(u) for u in upstreams)
            report.add("unbound upstream wired", wired, f"upstreams={upstreams}")
        except httpx.HTTPError as exc:
            report.add("unbound upstream wired", False, str(exc))
    finally:
        client.close()

    _render(c, report)
    raise typer.Exit(report.exit_code)


def _render(c: Ctx, report: dc.CheckReport):
    if c.as_json:
        dc.print_json(report.to_dict())
        return
    table = Table("check", "status", "detail", title="adguard check")
    style = {"pass": "green", "fail": "red", "skip": "yellow"}
    for chk in report.checks:
        table.add_row(chk.name, f"[{style[chk.status]}]{chk.status}[/]", chk.detail)
    console.print(table)
    console.print("[green]OK[/]" if report.passed else "[red]FAILED[/]")


if __name__ == "__main__":
    app()
