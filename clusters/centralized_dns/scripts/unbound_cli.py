#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "typer>=0.12",
#     "rich>=13",
#     "httpx>=0.27",
# ]
# ///
"""unbound_cli — verify & introspect the centralized_dns Unbound resolver via its exporter.

Unbound has no HTTP API, so this scrapes the `unbound_exporter` (:9167) Prometheus endpoint
(host-side HTTP, like the other cluster CLIs) and renders/asserts the key resolver stats. A
CI-friendly `check` confirms the exporter is up and Unbound is answering. Resolves the server
from `tofu output` (or `--server-url`). See specs/centralized_dns.md.

    uv run unbound_cli.py check --cluster centralized_dns
    uv run unbound_cli.py stats --json
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import NoReturn

import _dns_common as dc
import typer
from rich.console import Console
from rich.table import Table

PORT = 9167

# Metric name -> friendly label for the `stats` table.
STAT_KEYS = {
    "unbound_up": "exporter up",
    "unbound_queries_total": "queries total",
    "unbound_cache_hits_total": "cache hits",
    "unbound_cache_misses_total": "cache misses",
    "unbound_answers_secure_total": "DNSSEC secure answers",
    "unbound_memory_caches_bytes": "cache memory (bytes)",
}

app = typer.Typer(add_completion=False, no_args_is_help=True, help=__doc__)
console = Console()


@dataclass
class Options:
    cluster: str
    server_url: str | None
    as_json: bool
    timeout: float


@dataclass
class Ctx:
    base_url: str
    as_json: bool
    timeout: float


@app.callback()
def _main(
    ctx: typer.Context,
    cluster: str = typer.Option("centralized_dns", "--cluster"),
    server_url: str = typer.Option(
        None, "--server-url", help="override :9167 base; else tofu"
    ),
    as_json: bool = typer.Option(False, "--json", help="machine-readable JSON output"),
    timeout: float = typer.Option(10.0, "--timeout"),
):
    """Unbound verification CLI (via unbound_exporter)."""
    ctx.obj = Options(cluster, server_url, as_json, timeout)


def resolve(opts: Options) -> Ctx:
    target = dc.resolve_target(
        port=PORT,
        cluster=opts.cluster,
        server_url=opts.server_url,
        url_env="UNBOUND_EXPORTER_URL",
    )
    return Ctx(base_url=target.base_url, as_json=opts.as_json, timeout=opts.timeout)


def _die(msg: str, code: int = 1) -> NoReturn:
    console.print(f"[red]error:[/red] {msg}")
    raise typer.Exit(code)


def _scrape(c: Ctx) -> dict[str, float]:
    import httpx

    try:
        with httpx.Client(base_url=c.base_url, timeout=c.timeout) as client:
            resp = client.get("/metrics")
            resp.raise_for_status()
            return dc.parse_prometheus_metrics(resp.text)
    except httpx.HTTPError as exc:
        _die(f"could not scrape unbound_exporter at {c.base_url}/metrics: {exc}")


@app.command()
def stats(ctx: typer.Context):
    """Key Unbound resolver stats scraped from :9167/metrics."""
    c = resolve(ctx.obj)
    metrics = _scrape(c)
    if c.as_json:
        dc.print_json({k: metrics.get(k) for k in STAT_KEYS})
        return
    table = Table("stat", "value", title="unbound stats")
    for key, label in STAT_KEYS.items():
        val = metrics.get(key)
        table.add_row(label, "—" if val is None else str(val))
    console.print(table)


@app.command()
def check(ctx: typer.Context):
    """Assert unbound_exporter serves metrics and Unbound is answering; exit nonzero on failure."""
    c = resolve(ctx.obj)
    report = dc.CheckReport()

    metrics = _scrape(c)  # exits(1) on transport failure
    report.add("exporter /metrics reachable", True, f"{len(metrics)} series")

    up = metrics.get("unbound_up")
    report.add(
        "unbound reachable (unbound_up=1)",
        up == 1.0,
        f"unbound_up={up}",
    )
    report.add(
        "resolver serving queries",
        "unbound_queries_total" in metrics,
        f"queries_total={metrics.get('unbound_queries_total')}",
    )

    if c.as_json:
        dc.print_json(report.to_dict())
        raise typer.Exit(report.exit_code)
    table = Table("check", "status", "detail", title="unbound check")
    style = {"pass": "green", "fail": "red", "skip": "yellow"}
    for chk in report.checks:
        table.add_row(chk.name, f"[{style[chk.status]}]{chk.status}[/]", chk.detail)
    console.print(table)
    console.print("[green]OK[/]" if report.passed else "[red]FAILED[/]")
    raise typer.Exit(report.exit_code)


if __name__ == "__main__":
    app()
