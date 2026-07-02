#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "typer>=0.12",
#     "rich>=13",
#     "httpx>=0.27",
# ]
# ///
"""openobserve_cli — verify & introspect the cluster's OpenObserve over its REST API.

OpenObserve ships no read SDK, so this talks to the REST API directly with httpx.
Introspection (rich tables or `--json`) plus a CI-friendly `check` that asserts
OpenObserve is healthy and authentication works. Resolves the server from `tofu output`
(or `--server-url`). See specs/cli-openobserve.md.

    uv run openobserve_cli.py check --cluster centralized_monitoring
    uv run openobserve_cli.py streams --json
"""

from __future__ import annotations

import time
from dataclasses import dataclass

import _obs_common as oc
import typer
from rich.console import Console
from rich.table import Table

PORT = 5080
DEFAULT_USER = "admin@example.com"
DEFAULT_PASSWORD = "Complexpass#123"

app = typer.Typer(add_completion=False, no_args_is_help=True, help=__doc__)
console = Console()


@dataclass
class Options:
    cluster: str
    server_url: str | None
    user: str | None
    password: str | None
    org: str
    as_json: bool
    timeout: float
    insecure: bool


@dataclass
class Ctx:
    base_url: str
    user: str
    password: str
    org: str
    as_json: bool
    timeout: float
    insecure: bool

    def client(self):
        import httpx

        return httpx.Client(
            base_url=self.base_url,
            auth=(self.user, self.password),
            timeout=self.timeout,
            verify=not self.insecure,
        )


@app.callback()
def _main(
    ctx: typer.Context,
    cluster: str = typer.Option("centralized_monitoring", "--cluster"),
    server_url: str = typer.Option(None, "--server-url", help="override; else tofu"),
    user: str = typer.Option(
        None, "--user", help="default admin@example.com / $OPENOBSERVE_USER"
    ),
    password: str = typer.Option(None, "--password", help="$OPENOBSERVE_PASSWORD"),
    org: str = typer.Option("default", "--org"),
    as_json: bool = typer.Option(False, "--json", help="machine-readable JSON output"),
    timeout: float = typer.Option(10.0, "--timeout"),
    insecure: bool = typer.Option(False, "--insecure"),
):
    """OpenObserve verification CLI."""
    ctx.obj = Options(
        cluster, server_url, user, password, org, as_json, timeout, insecure
    )


def resolve(opts: Options) -> Ctx:
    target = oc.resolve_target(
        port=PORT,
        cluster=opts.cluster,
        server_url=opts.server_url,
        url_env="OPENOBSERVE_URL",
    )
    user, password = oc.resolve_credentials(
        opts.user,
        opts.password,
        user_env="OPENOBSERVE_USER",
        pass_env="OPENOBSERVE_PASSWORD",
        default_user=DEFAULT_USER,
        default_password=DEFAULT_PASSWORD,
    )
    return Ctx(
        base_url=target.base_url,
        user=user,
        password=password,
        org=opts.org,
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
    except Exception:  # noqa: BLE001 - non-JSON body (e.g. plain-text /healthz)
        return {"status_code": resp.status_code, "text": resp.text}


def _emit(c: Ctx, data, columns: list[str] | None = None, title: str | None = None):
    if c.as_json:
        oc.print_json(data)
        return
    if isinstance(data, list) and data and isinstance(data[0], dict):
        cols = columns or list(data[0].keys())
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
    """Liveness probe (GET /healthz)."""
    c = resolve(ctx.obj)
    import httpx

    try:
        with c.client() as client:
            resp = client.get("/healthz")
            resp.raise_for_status()
            data = _json_or_text(resp)
    except httpx.HTTPError as exc:
        _die(f"openobserve unreachable: {exc}")
    _emit(c, data, title="openobserve health")


@app.command()
def streams(ctx: typer.Context, type_: str = typer.Option(None, "--type")):
    """List ingest streams (GET /api/{org}/streams)."""
    c = resolve(ctx.obj)
    import httpx

    params = {"type": type_} if type_ else None
    try:
        with c.client() as client:
            resp = client.get(f"/api/{c.org}/streams", params=params)
            resp.raise_for_status()
            data = resp.json()
    except httpx.HTTPError as exc:
        _die(f"could not list streams: {exc}")
    rows = data.get("list", data) if isinstance(data, dict) else data
    _emit(c, rows, title="streams")


@app.command()
def search(
    ctx: typer.Context,
    sql: str = typer.Argument(...),
    start: int = typer.Option(None, "--start", help="start time (µs epoch)"),
    end: int = typer.Option(None, "--end", help="end time (µs epoch)"),
    size: int = typer.Option(100, "--size"),
):
    """Run a SQL search over a stream (POST /api/{org}/_search)."""
    c = resolve(ctx.obj)
    import httpx

    now_us = int(time.time() * 1_000_000)
    body = {
        "query": {
            "sql": sql,
            "start_time": start if start is not None else now_us - 3_600_000_000,
            "end_time": end if end is not None else now_us,
            "size": size,
        }
    }
    try:
        with c.client() as client:
            resp = client.post(f"/api/{c.org}/_search", json=body)
            resp.raise_for_status()
            data = resp.json()
    except httpx.HTTPError as exc:
        _die(f"search failed: {exc}")
    _emit(c, data.get("hits", data), title="search hits")


@app.command()
def query(ctx: typer.Context, promql: str = typer.Argument(...)):
    """PromQL-compatible metrics query (GET /api/{org}/prometheus/api/v1/query)."""
    c = resolve(ctx.obj)
    import httpx

    try:
        with c.client() as client:
            resp = client.get(
                f"/api/{c.org}/prometheus/api/v1/query", params={"query": promql}
            )
            resp.raise_for_status()
            data = resp.json()
    except httpx.HTTPError as exc:
        _die(f"query failed: {exc}")
    oc.print_json(data) if c.as_json else _emit(c, data, title=f"query: {promql}")


@app.command()
def orgs(ctx: typer.Context):
    """List organizations (GET /api/organizations)."""
    c = resolve(ctx.obj)
    import httpx

    try:
        with c.client() as client:
            resp = client.get("/api/organizations")
            resp.raise_for_status()
            data = resp.json()
    except httpx.HTTPError as exc:
        _die(f"could not list orgs: {exc}")
    _emit(c, data.get("data", data) if isinstance(data, dict) else data, title="orgs")


# --- check -------------------------------------------------------------------


@app.command()
def check(
    ctx: typer.Context,
    require_streams: bool = typer.Option(False, "--require-streams"),
    require_metrics: bool = typer.Option(
        False,
        "--require-metrics",
        help="fail unless PromQL `up` returns a series (metrics are being ingested)",
    ),
    require_logs: bool = typer.Option(
        False,
        "--require-logs",
        help="fail unless a logs stream has recent rows (logs are being ingested)",
    ),
):
    """Assert OpenObserve health + auth (+ optional streams/metrics/logs); exit nonzero on failure."""
    c = resolve(ctx.obj)
    import httpx

    report = oc.CheckReport()

    # 1. Health (/healthz, no auth strictly required).
    try:
        with httpx.Client(
            base_url=c.base_url, timeout=c.timeout, verify=not c.insecure
        ) as client:
            resp = client.get("/healthz")
            report.add("health", resp.status_code < 400, f"status={resp.status_code}")
    except httpx.HTTPError as exc:
        report.add("health", False, str(exc))
        _render_check(c, report)
        raise typer.Exit(report.exit_code)

    # 2. Auth works (streams endpoint requires basic auth).
    stream_count = None
    stream_items: list = []
    try:
        with c.client() as client:
            resp = client.get(f"/api/{c.org}/streams")
        if resp.status_code in (401, 403):
            report.add("auth", False, f"status={resp.status_code}")
        else:
            resp.raise_for_status()
            report.add("auth", True, f"status={resp.status_code}")
            data = resp.json()
            stream_items = (
                data.get("list", []) if isinstance(data, dict) else (data or [])
            )
            stream_count = len(stream_items)
    except httpx.HTTPError as exc:
        report.add("auth", False, str(exc))

    # 3. Streams present (reported always; only fails with --require-streams).
    if stream_count is None:
        report.skip("streams present", "streams not readable")
    elif require_streams:
        report.add("streams present", stream_count >= 1, f"{stream_count} streams")
    else:
        report.skip("streams present", f"{stream_count} streams (informational)")

    # 4. Metrics ingested — PromQL `up` returns at least one series (via remote_write).
    if require_metrics:
        try:
            with c.client() as client:
                resp = client.get(
                    f"/api/{c.org}/prometheus/api/v1/query", params={"query": "up"}
                )
                resp.raise_for_status()
                result = (resp.json().get("data") or {}).get("result") or []
            report.add(
                "metrics present", len(result) >= 1, f"{len(result)} series for up"
            )
        except httpx.HTTPError as exc:
            report.add("metrics present", False, str(exc))

    # 5. Logs ingested — a logs stream exists and has ≥1 recent row.
    if require_logs:
        logs_streams = [
            s
            for s in stream_items
            if isinstance(s, dict) and (s.get("stream_type") or s.get("type")) == "logs"
        ]
        if not logs_streams:
            report.add("logs present", False, "no logs streams")
        else:
            name = logs_streams[0].get("name")
            now_us = int(time.time() * 1_000_000)
            body = {
                "query": {
                    "sql": f'SELECT * FROM "{name}"',
                    "start_time": now_us - 3_600_000_000,
                    "end_time": now_us,
                    "size": 1,
                }
            }
            try:
                with c.client() as client:
                    resp = client.post(f"/api/{c.org}/_search", json=body)
                    resp.raise_for_status()
                    hits = resp.json().get("hits") or []
                report.add(
                    "logs present", len(hits) >= 1, f'{len(hits)} rows in "{name}"'
                )
            except httpx.HTTPError as exc:
                report.add("logs present", False, str(exc))

    _render_check(c, report)
    raise typer.Exit(report.exit_code)


def _render_check(c: Ctx, report: oc.CheckReport):
    if c.as_json:
        oc.print_json(report.to_dict())
        return
    table = Table("check", "status", "detail", title="openobserve check")
    colors = {"pass": "green", "fail": "red", "skip": "yellow"}
    for chk in report.checks:
        color = colors[chk.status]
        table.add_row(chk.name, f"[{color}]{chk.status}[/{color}]", chk.detail)
    console.print(table)
    verdict = "PASS" if report.passed else "FAIL"
    console.print(f"[{'green' if report.passed else 'red'}]{verdict}[/]")


if __name__ == "__main__":
    app()
