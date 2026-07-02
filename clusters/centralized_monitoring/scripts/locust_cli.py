#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "typer>=0.12",
#     "rich>=13",
#     "httpx>=0.27",
#     "locust>=2.31",
#     "faker>=30",
# ]
# ///
"""locust_cli — host-run Locust load generator for the centralized_monitoring cluster.

Resolves the server VM IP from `tofu output` (or `--server-url`) and points Locust at
its ingest/query surfaces (OpenObserve :5080, OTLP :4318, StatsD :8125/udp, Prometheus
:9090, Grafana :3000) so the dashboards show live traffic. See specs/locustio.md.

    uv run locust_cli.py run --cluster centralized_monitoring          # web UI :8089
    uv run locust_cli.py run --headless -u 20 -r 5 -t 2m               # headless
    uv run locust_cli.py check                                         # CI smoke run
    uv run locust_cli.py targets --json                               # print endpoints
"""

from __future__ import annotations

import os
import shutil
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

import _obs_common as oc
import typer
from rich.console import Console
from rich.table import Table

DEFAULT_USER = "admin@example.com"
DEFAULT_PASSWORD = "Complexpass#123"

OPENOBSERVE_PORT = 5080
OTLP_HTTP_PORT = 4318
STATSD_PORT = 8125
PROMETHEUS_PORT = 9090
GRAFANA_PORT = 3000

# `check` runs a short, low-concurrency headless burst.
CHECK_USERS = 3
CHECK_SPAWN = 3
CHECK_RUN_TIME = "10s"

LOCUSTFILE = Path(__file__).resolve().parent / "locustfiles" / "monitoring.py"

app = typer.Typer(add_completion=False, no_args_is_help=True, help=__doc__)
console = Console()


@dataclass
class Options:
    cluster: str
    server_url: str | None
    user: str | None
    password: str | None
    org: str
    users: int
    spawn_rate: float
    run_time: str | None
    headless: bool
    web_port: int
    as_json: bool
    timeout: float


@dataclass
class Ctx:
    ip: str
    user: str
    password: str
    org: str
    users: int
    spawn_rate: float
    run_time: str | None
    headless: bool
    web_port: int
    as_json: bool
    timeout: float


@app.callback()
def _main(
    ctx: typer.Context,
    cluster: str = typer.Option("centralized_monitoring", "--cluster"),
    server_url: str = typer.Option(
        None, "--server-url", help="override; else tofu ($LOCUST_TARGET_URL)"
    ),
    user: str = typer.Option(
        None,
        "--user",
        help="OpenObserve user; default admin@example.com / $OPENOBSERVE_USER",
    ),
    password: str = typer.Option(None, "--password", help="$OPENOBSERVE_PASSWORD"),
    org: str = typer.Option("default", "--org"),
    users: int = typer.Option(10, "--users", "-u", help="peak concurrent users"),
    spawn_rate: float = typer.Option(
        2.0, "--spawn-rate", "-r", help="users spawned/sec"
    ),
    run_time: str = typer.Option(
        None, "--run-time", "-t", help="e.g. 30s, 5m (headless only)"
    ),
    headless: bool = typer.Option(
        False, "--headless/--web", help="headless run vs web UI (default web)"
    ),
    web_port: int = typer.Option(8089, "--web-port"),
    as_json: bool = typer.Option(False, "--json", help="machine-readable JSON output"),
    timeout: float = typer.Option(10.0, "--timeout"),
):
    """Locust load-generator CLI."""
    ctx.obj = Options(
        cluster,
        server_url,
        user,
        password,
        org,
        users,
        spawn_rate,
        run_time,
        headless,
        web_port,
        as_json,
        timeout,
    )


def resolve(opts: Options) -> Ctx:
    target = oc.resolve_target(
        port=OPENOBSERVE_PORT,
        cluster=opts.cluster,
        server_url=opts.server_url,
        url_env="LOCUST_TARGET_URL",
    )
    # tofu path yields target.ip; a --server-url/env override yields only base_url.
    ip = target.ip or urlparse(target.base_url).hostname or target.base_url
    user, password = oc.resolve_credentials(
        opts.user,
        opts.password,
        user_env="OPENOBSERVE_USER",
        pass_env="OPENOBSERVE_PASSWORD",
        default_user=DEFAULT_USER,
        default_password=DEFAULT_PASSWORD,
    )
    return Ctx(
        ip=ip,
        user=user,
        password=password,
        org=opts.org,
        users=opts.users,
        spawn_rate=opts.spawn_rate,
        run_time=opts.run_time,
        headless=opts.headless,
        web_port=opts.web_port,
        as_json=opts.as_json,
        timeout=opts.timeout,
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
    elif isinstance(data, dict):
        table = Table("field", "value", title=title)
        for key, value in data.items():
            table.add_row(str(key), str(value))
        console.print(table)
    else:
        console.print(str(data))


# --- Locust invocation seams (monkeypatched in hermetic tests) ---------------


def _locust_bin() -> str:
    """The `locust` console script for the current (uv) environment."""
    candidate = Path(sys.executable).parent / "locust"
    if candidate.exists():
        return str(candidate)
    return shutil.which("locust") or "locust"


def _build_locust_argv(
    *,
    ip: str,
    locustfile: Path,
    headless: bool,
    users: int | None = None,
    spawn_rate: float | None = None,
    run_time: str | None = None,
    web_port: int | None = None,
    csv_prefix: str | None = None,
) -> list[str]:
    """Assemble the `locust` argv. Pure — no side effects — so tests can assert it.

    No ``--host`` is passed: each ``HttpUser`` subclass in ``monitoring.py`` declares
    its own ``host`` (OpenObserve :5080, OTLP :4318, Prometheus :9090; Grafana via an
    absolute URL). A CLI ``--host`` overrides *every* selected user's ``host``, which
    would misroute the OTLP and Prometheus load to :5080 (404). The target IP still
    reaches the swarm via ``LOCUST_TARGET_IP`` (see ``_locust_env``).
    """
    argv = [
        _locust_bin(),
        "-f",
        str(locustfile),
    ]
    if headless:
        argv.append("--headless")
        if users is not None:
            argv += ["-u", str(users)]
        if spawn_rate is not None:
            argv += ["-r", str(spawn_rate)]
        if run_time:
            argv += ["-t", run_time]
        if csv_prefix:
            argv += ["--csv", csv_prefix]
    elif web_port is not None:
        argv += ["--web-port", str(web_port)]
    return argv


def _locust_env(c: Ctx) -> dict:
    env = dict(os.environ)
    env.update(
        {
            "LOCUST_TARGET_IP": c.ip,
            "OO_USER": c.user,
            "OO_PASSWORD": c.password,
            "OO_ORG": c.org,
        }
    )
    return env


def _run_locust(argv: list[str], env: dict) -> int:
    """Run Locust, streaming its output; return the exit code."""
    import subprocess

    return subprocess.run(argv, env=env).returncode


def _parse_stats_csv(path: str) -> dict:
    """Parse a Locust `--csv` stats file into {num_requests, num_failures}."""
    import csv

    total_req = total_fail = 0
    aggregated: tuple[int, int] | None = None
    try:
        with open(path, newline="") as fh:
            for row in csv.DictReader(fh):
                name = (row.get("Name") or "").strip()
                req = int(float(row.get("Request Count", 0) or 0))
                fail = int(float(row.get("Failure Count", 0) or 0))
                if name == "Aggregated":
                    aggregated = (req, fail)
                else:
                    total_req += req
                    total_fail += fail
    except FileNotFoundError:
        return {"num_requests": 0, "num_failures": 0}
    if aggregated is not None:
        return {"num_requests": aggregated[0], "num_failures": aggregated[1]}
    return {"num_requests": total_req, "num_failures": total_fail}


# --- commands ----------------------------------------------------------------


@app.command()
def targets(ctx: typer.Context):
    """Print the resolved endpoints Locust will drive (no load)."""
    c = resolve(ctx.obj)
    rows = [
        {
            "service": "openobserve",
            "endpoint": f"http://{c.ip}:{OPENOBSERVE_PORT}/api/{c.org}/loadtest/_json",
        },
        {"service": "otlp-http", "endpoint": f"http://{c.ip}:{OTLP_HTTP_PORT}/v1/logs"},
        {"service": "statsd", "endpoint": f"udp://{c.ip}:{STATSD_PORT}"},
        {
            "service": "prometheus",
            "endpoint": f"http://{c.ip}:{PROMETHEUS_PORT}/api/v1/query",
        },
        {"service": "grafana", "endpoint": f"http://{c.ip}:{GRAFANA_PORT}/api/health"},
    ]
    _emit(c, rows, columns=["service", "endpoint"], title=f"locust targets ({c.ip})")


@app.command()
def run(ctx: typer.Context):
    """Launch Locust against the resolved host (web UI by default)."""
    c = resolve(ctx.obj)
    argv = _build_locust_argv(
        ip=c.ip,
        locustfile=LOCUSTFILE,
        headless=c.headless,
        users=c.users,
        spawn_rate=c.spawn_rate,
        run_time=c.run_time,
        web_port=c.web_port,
    )
    if not c.headless:
        console.print(
            f"launching Locust web UI on http://localhost:{c.web_port} → target {c.ip}"
        )
    rc = _run_locust(argv, _locust_env(c))
    raise typer.Exit(rc)


@app.command()
def check(ctx: typer.Context):
    """Short headless run; assert requests fired with zero failures. Exit nonzero on failure."""
    opts: Options = ctx.obj
    report = oc.CheckReport()

    try:
        c = resolve(opts)
    except Exception as exc:  # noqa: BLE001 - any resolution failure => unresolved target
        report.add("target resolved", False, str(exc))
        _render_check(opts.as_json, report)
        raise typer.Exit(report.exit_code)

    report.add("target resolved", True, c.ip)

    with tempfile.TemporaryDirectory() as tmp:
        prefix = os.path.join(tmp, "locust")
        argv = _build_locust_argv(
            ip=c.ip,
            locustfile=LOCUSTFILE,
            headless=True,
            users=CHECK_USERS,
            spawn_rate=CHECK_SPAWN,
            run_time=c.run_time or CHECK_RUN_TIME,
            csv_prefix=prefix,
        )
        rc = _run_locust(argv, _locust_env(c))
        stats = _parse_stats_csv(prefix + "_stats.csv")

    report.add(
        "load ran",
        stats["num_requests"] > 0,
        f"{stats['num_requests']} requests (locust rc={rc})",
    )
    report.add(
        "no failures", stats["num_failures"] == 0, f"{stats['num_failures']} failures"
    )

    _render_check(c.as_json, report)
    raise typer.Exit(report.exit_code)


def _render_check(as_json: bool, report: oc.CheckReport):
    if as_json:
        oc.print_json(report.to_dict())
        return
    table = Table("check", "status", "detail", title="locust check")
    colors = {"pass": "green", "fail": "red", "skip": "yellow"}
    for chk in report.checks:
        color = colors[chk.status]
        table.add_row(chk.name, f"[{color}]{chk.status}[/{color}]", chk.detail)
    console.print(table)
    verdict = "PASS" if report.passed else "FAIL"
    console.print(f"[{'green' if report.passed else 'red'}]{verdict}[/]")


if __name__ == "__main__":
    app()
