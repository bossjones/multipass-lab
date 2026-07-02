#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "typer>=0.12",
#     "rich>=13",
#     "grafana-client>=5",
# ]
# ///
"""grafana_cli — verify & introspect the cluster's Grafana over its HTTP API.

Introspection (rich tables or `--json`) plus a CI-friendly `check` that asserts Grafana
is healthy, its Prometheus/OpenObserve datasources are reachable, and dashboards
provisioned — exiting nonzero on failure. Resolves the server from `tofu output` (or
`--server-url`). See specs/cli-grafana.md.

    uv run grafana_cli.py check --cluster centralized_monitoring
    uv run grafana_cli.py datasources --json
"""

from __future__ import annotations

from dataclasses import dataclass, field

import _obs_common as oc
import typer
from rich.console import Console
from rich.table import Table

PORT = 3000
DEFAULT_USER = "admin"
DEFAULT_PASSWORD = "admin"

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
    insecure: bool


@dataclass
class Ctx:
    base_url: str
    user: str
    password: str
    as_json: bool
    timeout: float
    insecure: bool
    enabled_flags: set = field(default_factory=set)

    def client(self):
        from grafana_client import GrafanaApi

        return GrafanaApi.from_url(
            self.base_url,
            credential=(self.user, self.password),
            timeout=self.timeout,
        )


@app.callback()
def _main(
    ctx: typer.Context,
    cluster: str = typer.Option("centralized_monitoring", "--cluster"),
    server_url: str = typer.Option(None, "--server-url", help="override; else tofu"),
    user: str = typer.Option(None, "--user", help="default admin / $GRAFANA_USER"),
    password: str = typer.Option(None, "--password", help="default admin / $GRAFANA_PASSWORD"),
    as_json: bool = typer.Option(False, "--json", help="machine-readable JSON output"),
    timeout: float = typer.Option(10.0, "--timeout"),
    insecure: bool = typer.Option(False, "--insecure", help="skip TLS verification"),
):
    """Grafana verification CLI."""
    ctx.obj = Options(cluster, server_url, user, password, as_json, timeout, insecure)


# --- resolution + output helpers ---------------------------------------------


def resolve(opts: Options) -> Ctx:
    target = oc.resolve_target(
        port=PORT,
        cluster=opts.cluster,
        server_url=opts.server_url,
        url_env="GRAFANA_URL",
    )
    user, password = oc.resolve_credentials(
        opts.user,
        opts.password,
        user_env="GRAFANA_USER",
        pass_env="GRAFANA_PASSWORD",
        default_user=DEFAULT_USER,
        default_password=DEFAULT_PASSWORD,
    )
    return Ctx(
        base_url=target.base_url,
        user=user,
        password=password,
        as_json=opts.as_json,
        timeout=opts.timeout,
        insecure=opts.insecure,
        enabled_flags=target.enabled_flags,
    )


def _die(msg: str, code: int = 1):
    console.print(f"[red]error:[/red] {msg}")
    raise typer.Exit(code)


def _emit(c: Ctx, data, columns: list[str] | None = None, title: str | None = None):
    """Print `data` as JSON (``--json``) or a rich table."""
    if c.as_json:
        oc.print_json(data)
        return
    if isinstance(data, list):
        cols = columns or (list(data[0].keys()) if data else [])
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
    """Grafana server health (GET /api/health)."""
    c = resolve(ctx.obj)
    try:
        data = oc.http_get_json(
            c.base_url + "/api/health", timeout=c.timeout, insecure=c.insecure
        )
    except oc.HttpError as exc:
        _die(f"grafana unreachable: {exc}")
    _emit(c, data, title="grafana health")


@app.command()
def datasources(ctx: typer.Context):
    """List provisioned datasources."""
    c = resolve(ctx.obj)
    try:
        items = c.client().datasource.list_datasources()
    except Exception as exc:  # noqa: BLE001 - surface any client/transport error
        _die(f"could not list datasources: {exc}")
    rows = [
        {
            "name": d.get("name"),
            "type": d.get("type"),
            "uid": d.get("uid"),
            "url": d.get("url", ""),
        }
        for d in items
    ]
    _emit(c, rows, columns=["name", "type", "uid", "url"], title="datasources")


def _find_datasource(client, name: str):
    for d in client.datasource.list_datasources():
        if d.get("name", "").lower() == name.lower():
            return d
    return None


@app.command(name="datasource-health")
def datasource_health(ctx: typer.Context, name: str = typer.Argument(...)):
    """Server-side health check for a datasource by name."""
    c = resolve(ctx.obj)
    client = c.client()
    try:
        ds = _find_datasource(client, name)
        if ds is None:
            _die(f"no datasource named {name!r}")
        result = client.datasource.health(ds["uid"])
    except oc.HttpError as exc:  # from _find via client? unlikely
        _die(str(exc))
    except typer.Exit:
        raise
    except Exception as exc:  # noqa: BLE001
        _die(f"health check failed: {exc}")
    _emit(c, result, title=f"datasource-health: {name}")


@app.command()
def dashboards(ctx: typer.Context):
    """List provisioned dashboards (type=dash-db)."""
    c = resolve(ctx.obj)
    try:
        items = c.client().search.search_dashboards(type_="dash-db")
    except Exception as exc:  # noqa: BLE001
        _die(f"could not search dashboards: {exc}")
    rows = [
        {
            "uid": d.get("uid"),
            "title": d.get("title"),
            "folder": d.get("folderTitle", ""),
        }
        for d in items
    ]
    _emit(c, rows, columns=["uid", "title", "folder"], title="dashboards")


@app.command()
def dashboard(ctx: typer.Context, uid: str = typer.Argument(...)):
    """Dump one dashboard by uid (JSON)."""
    c = resolve(ctx.obj)
    try:
        data = c.client().dashboard.get_dashboard(uid)
    except Exception as exc:  # noqa: BLE001
        _die(f"could not fetch dashboard {uid!r}: {exc}")
    oc.print_json(data)


@app.command(name="alert-rules")
def alert_rules(ctx: typer.Context):
    """List Grafana-managed alert rules (empty in this lab — alerts live in Prometheus)."""
    c = resolve(ctx.obj)
    try:
        data = oc.http_get_json(
            c.base_url + "/api/v1/provisioning/alert-rules",
            auth=(c.user, c.password),
            timeout=c.timeout,
            insecure=c.insecure,
        )
    except oc.HttpError as exc:
        if exc.status == 404:
            data = []
        else:
            _die(f"could not list alert rules: {exc}")
    _emit(c, data or [], title="alert-rules")


# --- check -------------------------------------------------------------------


def _check_datasource_health(client, ds, report, label):
    try:
        result = client.datasource.health(ds["uid"])
        status = (result.get("status") or "").upper()
        report.add(label, status == "OK", f"status={result.get('status')}")
    except Exception as exc:  # noqa: BLE001
        report.add(label, False, str(exc))


@app.command()
def check(
    ctx: typer.Context,
    min_dashboards: int = typer.Option(1, "--min-dashboards"),
):
    """Assert Grafana health + datasources + dashboards; exit nonzero on failure."""
    c = resolve(ctx.obj)
    report = oc.CheckReport()

    # 1. Grafana health (canonical /api/health, unauthenticated).
    try:
        data = oc.http_get_json(
            c.base_url + "/api/health", timeout=c.timeout, insecure=c.insecure
        )
        report.add(
            "grafana health",
            (data or {}).get("database") == "ok",
            f"database={(data or {}).get('database')}",
        )
    except oc.HttpError as exc:
        report.add("grafana health", False, str(exc))

    # 2/3. Datasources present + healthy.
    by_name = {}
    try:
        by_name = {d.get("name"): d for d in c.client().datasource.list_datasources()}
        listed = True
    except Exception as exc:  # noqa: BLE001
        report.add("datasources", False, str(exc))
        listed = False

    if listed:
        client = c.client()
        if "Prometheus" in by_name:
            _check_datasource_health(
                client, by_name["Prometheus"], report, "prometheus datasource"
            )
        else:
            report.add("prometheus datasource", False, "not provisioned")

        if "OpenObserve" in by_name:
            _check_datasource_health(
                client, by_name["OpenObserve"], report, "openobserve datasource"
            )
        elif "enable_openobserve" in c.enabled_flags:
            report.add("openobserve datasource", False, "expected but not provisioned")
        else:
            report.skip("openobserve datasource", "enable_openobserve off / unknown")

    # 4. Dashboards provisioned.
    try:
        found = c.client().search.search_dashboards(type_="dash-db")
        report.add(
            "dashboards provisioned",
            len(found) >= min_dashboards,
            f"{len(found)} found (min {min_dashboards})",
        )
    except Exception as exc:  # noqa: BLE001
        report.add("dashboards provisioned", False, str(exc))

    _render_check(c, report)
    raise typer.Exit(report.exit_code)


def _render_check(c: Ctx, report: oc.CheckReport):
    if c.as_json:
        oc.print_json(report.to_dict())
        return
    table = Table("check", "status", "detail", title="grafana check")
    colors = {"pass": "green", "fail": "red", "skip": "yellow"}
    for chk in report.checks:
        color = colors[chk.status]
        table.add_row(chk.name, f"[{color}]{chk.status}[/{color}]", chk.detail)
    console.print(table)
    verdict = "PASS" if report.passed else "FAIL"
    console.print(f"[{'green' if report.passed else 'red'}]{verdict}[/]")


if __name__ == "__main__":
    app()
