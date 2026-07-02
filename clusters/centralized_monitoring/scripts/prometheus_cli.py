#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "typer>=0.12",
#     "rich>=13",
#     "prometheus-api-client>=0.5",
# ]
# ///
"""prometheus_cli — verify & introspect the cluster's Prometheus over its HTTP API.

Introspection (rich tables or `--json`) plus a CI-friendly `check` that asserts
Prometheus is scraping and no target is down — flag-aware via `tofu` so a disabled
exporter is skipped, not failed. Resolves the server from `tofu output` (or
`--server-url`). See specs/cli-prometheus.md.

    uv run prometheus_cli.py check --cluster centralized_monitoring
    uv run prometheus_cli.py query 'up' --json
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime

import _obs_common as oc
import typer
from rich.console import Console
from rich.table import Table

PORT = 9090

# enable_* flag -> the Prometheus scrape job it turns on (see docs/endpoints.md). Used to
# make `check` job-aware: only jobs whose flag is on are expected to have live targets.
FLAG_JOBS = {
    "enable_node_exporter": "node",
    "enable_cadvisor": "cadvisor",
    "enable_process_exporter": "process",
    "enable_netdata": "netdata",
    "enable_kube_state_metrics": "kube-state-metrics",
    "enable_kubelet_scrape": "kubelet",
    "enable_filestat_exporter": "filestat",
    "enable_statsd_exporter": "statsd",
    "enable_ssh_exporter": "ssh",
    "enable_traefik": "traefik",
    "enable_blackbox": "blackbox",
}

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
    as_json: bool
    timeout: float
    insecure: bool
    enabled_flags: set = field(default_factory=set)

    def client(self):
        from prometheus_api_client import PrometheusConnect

        return PrometheusConnect(
            url=self.base_url, disable_ssl=True if self.insecure else False
        )


@app.callback()
def _main(
    ctx: typer.Context,
    cluster: str = typer.Option("centralized_monitoring", "--cluster"),
    server_url: str = typer.Option(None, "--server-url", help="override; else tofu"),
    as_json: bool = typer.Option(False, "--json", help="machine-readable JSON output"),
    timeout: float = typer.Option(10.0, "--timeout"),
    insecure: bool = typer.Option(False, "--insecure"),
):
    """Prometheus verification CLI (Prometheus is unauthenticated in this lab)."""
    ctx.obj = Options(cluster, server_url, as_json, timeout, insecure)


def resolve(opts: Options) -> Ctx:
    target = oc.resolve_target(
        port=PORT,
        cluster=opts.cluster,
        server_url=opts.server_url,
        url_env="PROMETHEUS_URL",
    )
    return Ctx(
        base_url=target.base_url,
        as_json=opts.as_json,
        timeout=opts.timeout,
        insecure=opts.insecure,
        enabled_flags=target.enabled_flags,
    )


def _die(msg: str, code: int = 1):
    console.print(f"[red]error:[/red] {msg}")
    raise typer.Exit(code)


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
    elif isinstance(data, list):
        table = Table(title or "value")
        for item in data:
            table.add_row(str(item))
        console.print(table)
    else:
        console.print(str(data))


# --- introspection commands --------------------------------------------------


@app.command()
def query(ctx: typer.Context, promql: str = typer.Argument(...)):
    """Instant PromQL query (GET /api/v1/query)."""
    c = resolve(ctx.obj)
    try:
        result = c.client().custom_query(query=promql, timeout=int(c.timeout))
    except Exception as exc:  # noqa: BLE001
        _die(f"query failed: {exc}")
    if c.as_json:
        oc.print_json(result)
        return
    rows = [
        {"metric": r.get("metric", {}), "value": (r.get("value") or ["", ""])[1]}
        for r in result
    ]
    _emit(c, rows, columns=["metric", "value"], title=f"query: {promql}")


@app.command(name="query-range")
def query_range(
    ctx: typer.Context,
    promql: str = typer.Argument(...),
    start: str = typer.Option(..., "--start", help="ISO-8601 start time"),
    end: str = typer.Option(..., "--end", help="ISO-8601 end time"),
    step: str = typer.Option("15s", "--step"),
):
    """Range PromQL query (GET /api/v1/query_range)."""
    c = resolve(ctx.obj)
    try:
        result = c.client().custom_query_range(
            query=promql,
            start_time=datetime.fromisoformat(start),
            end_time=datetime.fromisoformat(end),
            step=step,
        )
    except Exception as exc:  # noqa: BLE001
        _die(f"range query failed: {exc}")
    oc.print_json(result)


@app.command()
def targets(ctx: typer.Context, state: str = typer.Option(None, "--state")):
    """List scrape targets and per-target health (GET /api/v1/targets)."""
    c = resolve(ctx.obj)
    try:
        data = c.client().get_targets(state=state)
    except Exception as exc:  # noqa: BLE001
        _die(f"could not fetch targets: {exc}")
    rows = [
        {
            "job": t.get("labels", {}).get("job") or t.get("scrapePool", ""),
            "instance": t.get("labels", {}).get("instance", ""),
            "health": t.get("health", ""),
            "lastError": t.get("lastError", ""),
        }
        for t in data.get("activeTargets", [])
    ]
    _emit(c, rows, columns=["job", "instance", "health", "lastError"], title="targets")


@app.command()
def alerts(ctx: typer.Context):
    """List active alerts (GET /api/v1/alerts)."""
    c = resolve(ctx.obj)
    try:
        data = oc.http_get_json(
            c.base_url + "/api/v1/alerts", timeout=c.timeout, insecure=c.insecure
        )
    except oc.HttpError as exc:
        _die(f"could not fetch alerts: {exc}")
    _emit(c, data.get("data", {}).get("alerts", []), title="alerts")


@app.command()
def rules(ctx: typer.Context):
    """List alerting/recording rule groups (GET /api/v1/rules)."""
    c = resolve(ctx.obj)
    try:
        data = oc.http_get_json(
            c.base_url + "/api/v1/rules", timeout=c.timeout, insecure=c.insecure
        )
    except oc.HttpError as exc:
        _die(f"could not fetch rules: {exc}")
    _emit(c, data.get("data", {}).get("groups", []), title="rules")


@app.command()
def labels(ctx: typer.Context):
    """List label names (GET /api/v1/labels)."""
    c = resolve(ctx.obj)
    try:
        result = c.client().get_label_names()
    except Exception as exc:  # noqa: BLE001
        _die(f"could not fetch labels: {exc}")
    _emit(c, result, title="labels")


@app.command(name="label-values")
def label_values(ctx: typer.Context, label: str = typer.Argument(...)):
    """List values for a label (GET /api/v1/label/{label}/values)."""
    c = resolve(ctx.obj)
    try:
        result = c.client().get_label_values(label_name=label)
    except Exception as exc:  # noqa: BLE001
        _die(f"could not fetch label values: {exc}")
    _emit(c, result, title=f"label-values: {label}")


@app.command()
def metrics(ctx: typer.Context):
    """List all scraped metric names (GET /api/v1/label/__name__/values)."""
    c = resolve(ctx.obj)
    try:
        result = c.client().all_metrics()
    except Exception as exc:  # noqa: BLE001
        _die(f"could not fetch metrics: {exc}")
    _emit(c, result, title="metrics")


# --- check -------------------------------------------------------------------


@app.command()
def check(ctx: typer.Context):
    """Assert Prometheus is scraping and no target is down; exit nonzero on failure."""
    c = resolve(ctx.obj)
    report = oc.CheckReport()
    client = c.client()

    # 1. Reachable + scraping (`up` returns at least one series).
    try:
        up = client.custom_query(query="up")
        report.add("prometheus reachable", len(up) >= 1, f"{len(up)} 'up' series")
    except Exception as exc:  # noqa: BLE001
        report.add("prometheus reachable", False, str(exc))
        _render_check(c, report)
        raise typer.Exit(report.exit_code)

    # 2. No down active targets.
    active_jobs: dict[str, list[str]] = {}
    try:
        data = client.get_targets()
        active = data.get("activeTargets", [])
        for t in active:
            job = t.get("labels", {}).get("job") or t.get("scrapePool")
            active_jobs.setdefault(job, []).append(t.get("health"))
        down = [t for t in active if t.get("health") == "down"]
        report.add(
            "no down targets",
            len(down) == 0,
            f"{len(down)} down / {len(active)} active",
        )
    except Exception as exc:  # noqa: BLE001
        report.add("no down targets", False, str(exc))

    # 3. Flag-aware expected jobs (skipped in --server-url mode where tofu isn't read).
    expected = {FLAG_JOBS[f] for f in c.enabled_flags if f in FLAG_JOBS}
    if not expected:
        report.skip("expected jobs", "no tofu flags (server-url mode)")
    else:
        for job in sorted(expected):
            healths = active_jobs.get(job, [])
            ok = bool(healths) and all(h != "down" for h in healths)
            report.add(f"job {job}", ok, str(healths or "absent"))

    _render_check(c, report)
    raise typer.Exit(report.exit_code)


def _render_check(c: Ctx, report: oc.CheckReport):
    if c.as_json:
        oc.print_json(report.to_dict())
        return
    table = Table("check", "status", "detail", title="prometheus check")
    colors = {"pass": "green", "fail": "red", "skip": "yellow"}
    for chk in report.checks:
        color = colors[chk.status]
        table.add_row(chk.name, f"[{color}]{chk.status}[/{color}]", chk.detail)
    console.print(table)
    verdict = "PASS" if report.passed else "FAIL"
    console.print(f"[{'green' if report.passed else 'red'}]{verdict}[/]")


if __name__ == "__main__":
    app()
