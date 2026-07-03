"""ooctl — async CLI to tail and search logs from an OpenObserve instance.

Connection details come from a YAML profiles config (``~/.ooctl/config.yaml`` by
default; see ``example.config.yaml``). Select a profile with ``--profile`` and
override the endpoint at runtime with ``$OOCTL_ENDPOINT``.

    ooctl configure list
    ooctl logs tail -f --profile default --stream default
    ooctl logs search --sql 'SELECT * FROM default' --since 1h
"""

from __future__ import annotations

import asyncio
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, NoReturn

import typer
import yaml
from rich.console import Console
from rich.table import Table

from ooctl.client import OpenObserveClient, SearchError
from ooctl.config import (
    ConfigError,
    Profile,
    default_config_path,
    load_config,
    resolve_profile,
)
from ooctl.render import write_hit
from ooctl.tail import now_micros, run_tail

app = typer.Typer(add_completion=False, no_args_is_help=True, help=__doc__)
logs_app = typer.Typer(add_completion=False, no_args_is_help=True, help="Tail and search logs.")
configure_app = typer.Typer(add_completion=False, no_args_is_help=True, help="Manage profiles.")
streams_app = typer.Typer(add_completion=False, no_args_is_help=True, help="Inspect streams.")
app.add_typer(logs_app, name="logs")
app.add_typer(configure_app, name="configure")
app.add_typer(streams_app, name="streams")

console = Console()

_DURATION = re.compile(r"^\s*(\d+)\s*([smhd])\s*$")
_UNIT_SECONDS = {"s": 1, "m": 60, "h": 3600, "d": 86400}


@dataclass
class GlobalOpts:
    config: str | None
    profile: str


@app.callback()
def _main(
    ctx: typer.Context,
    config: str = typer.Option(
        None, "--config", help="config file (default ~/.ooctl/config.yaml or $OOCTL_CONFIG)"
    ),
    profile: str = typer.Option("default", "--profile", "-p", help="profile name"),
) -> None:
    ctx.obj = GlobalOpts(config=config, profile=profile)


# -- helpers ---------------------------------------------------------------


def _die(msg: str, code: int = 1) -> NoReturn:
    console.print(f"[red]error:[/red] {msg}")
    raise typer.Exit(code)


def _config_path(opts: GlobalOpts) -> Path:
    return Path(opts.config or os.environ.get("OOCTL_CONFIG") or default_config_path())


def _resolve(ctx: typer.Context) -> Profile:
    opts: GlobalOpts = ctx.obj
    try:
        cfg = load_config(_config_path(opts))
        return resolve_profile(cfg, opts.profile)
    except ConfigError as exc:
        _die(str(exc))


def _client(profile: Profile) -> OpenObserveClient:
    return OpenObserveClient(
        endpoint=profile.endpoint,
        organization=profile.organization,
        username=profile.username,
        password=profile.password,
        timeout=profile.timeout,
        verify=profile.verify,
    )


def _parse_since(text: str) -> int:
    """``5m`` / ``1h`` / ``30s`` / ``2d`` -> absolute start timestamp in micros."""
    match = _DURATION.match(text)
    if not match:
        _die(f"invalid --since {text!r}; use e.g. 30s, 5m, 1h, 2d")
    value, unit = int(match.group(1)), match.group(2)
    return now_micros() - value * _UNIT_SECONDS[unit] * 1_000_000


def _emit(as_json: bool, rows: list[dict[str, Any]], *, columns: list[str], title: str) -> None:
    if as_json:
        console.print_json(data=rows)
        return
    table = Table(title=title)
    for col in columns:
        table.add_column(col)
    for row in rows:
        table.add_row(*(str(row.get(col, "")) for col in columns))
    console.print(table)


# -- configure -------------------------------------------------------------


@configure_app.command("list")
def configure_list(
    ctx: typer.Context,
    as_json: bool = typer.Option(False, "--json", help="machine-readable output"),
) -> None:
    """List configured profiles (passwords redacted)."""
    opts: GlobalOpts = ctx.obj
    try:
        cfg = load_config(_config_path(opts))
    except ConfigError as exc:
        _die(str(exc))
    rows = [
        {
            "profile": name,
            "endpoint": p.endpoint,
            "organization": p.organization,
            "username": p.username,
            "password": "***",
        }
        for name, p in cfg.profiles.items()
    ]
    _emit(
        as_json,
        rows,
        columns=["profile", "endpoint", "organization", "username", "password"],
        title="profiles",
    )


@configure_app.command("add")
def configure_add(
    ctx: typer.Context,
    name: str = typer.Argument(..., help="profile name"),
    endpoint: str = typer.Option(..., "--endpoint"),
    username: str = typer.Option(..., "--username"),
    password: str = typer.Option(..., "--password"),
    organization: str = typer.Option("default", "--org"),
) -> None:
    """Add (or overwrite) a profile in the config file."""
    opts: GlobalOpts = ctx.obj
    path = _config_path(opts)
    raw = yaml.safe_load(path.read_text()) if path.exists() else {}
    raw = raw or {}
    raw.setdefault("profiles", {})
    raw["profiles"][name] = {
        "endpoint": endpoint,
        "organization": organization,
        "username": username,
        "password": password,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(yaml.safe_dump(raw, sort_keys=True))
    console.print(f"[green]added[/green] profile {name!r} -> {path}")


# -- streams ---------------------------------------------------------------


@streams_app.command("list")
def streams_list(
    ctx: typer.Context,
    stream_type: str = typer.Option(None, "--type", help="filter by stream type, e.g. logs"),
    as_json: bool = typer.Option(False, "--json"),
) -> None:
    """List ingest streams."""
    profile = _resolve(ctx)

    async def _run() -> list[dict[str, Any]]:
        async with _client(profile) as c:
            return await c.streams(stream_type=stream_type)

    try:
        rows = asyncio.run(_run())
    except SearchError as exc:
        _die(str(exc), code=2)
    _emit(as_json, rows, columns=["name", "stream_type"], title="streams")


# -- health ----------------------------------------------------------------


@app.command()
def health(ctx: typer.Context) -> None:
    """Check OpenObserve liveness; exit nonzero if unhealthy."""
    profile = _resolve(ctx)

    async def _run() -> bool:
        async with _client(profile) as c:
            return await c.health()

    if asyncio.run(_run()):
        console.print("[green]ok[/green]")
    else:
        _die(f"OpenObserve unhealthy at {profile.endpoint}", code=2)


# -- logs ------------------------------------------------------------------


@logs_app.command("search")
def logs_search(
    ctx: typer.Context,
    sql: str = typer.Option(None, "--sql", help="raw SQL; else --stream is queried"),
    stream: str = typer.Option(None, "--stream", help="stream name to query"),
    since: str = typer.Option("1h", "--since", help="lookback window, e.g. 30s/5m/1h/2d"),
    limit: int = typer.Option(100, "--limit", help="max rows"),
    as_json: bool = typer.Option(False, "--json"),
) -> None:
    """One-shot bounded search over a stream (uses the streaming SSE endpoint)."""
    if not sql and not stream:
        _die("provide --sql or --stream")
    profile = _resolve(ctx)
    query = sql or f'SELECT * FROM "{stream}" ORDER BY _timestamp DESC'
    start, end = _parse_since(since), now_micros()

    async def _run() -> None:
        async with _client(profile) as c:
            async for hit in c.search_stream(sql=query, start_time=start, end_time=end, size=limit):
                write_hit(console, hit, as_json=as_json)

    try:
        asyncio.run(_run())
    except SearchError as exc:
        _die(str(exc), code=2)


@logs_app.command("tail")
def logs_tail(
    ctx: typer.Context,
    stream: list[str] = typer.Option(None, "--stream", help="stream(s) to tail (repeatable)"),
    follow: bool = typer.Option(False, "-f", "--follow", help="keep following new logs"),
    since: str = typer.Option("5m", "--since", help="initial lookback, e.g. 30s/5m/1h"),
    sql: str = typer.Option(None, "--sql", help="raw SQL (overrides --stream ordering)"),
    interval: float = typer.Option(2.0, "--interval", help="poll interval seconds (with -f)"),
    limit: int = typer.Option(200, "--limit", help="max rows per poll"),
    as_json: bool = typer.Option(False, "--json"),
) -> None:
    """Tail logs. Without -f, prints one window and exits; with -f, follows live."""
    profile = _resolve(ctx)
    if stream:
        streams = list(stream)
    elif sql:
        streams = ["query"]  # single producer driven by --sql
    else:
        streams = ["default"]
    since_micros = _parse_since(since)

    def _on_hit(hit: dict[str, Any]) -> None:
        write_hit(console, hit, as_json=as_json)

    async def _run() -> None:
        async with _client(profile) as c:
            await run_tail(
                c,
                streams=streams,
                sql=sql,
                since_micros=since_micros,
                interval=interval,
                size=limit,
                follow=follow,
                on_hit=_on_hit,
            )

    try:
        asyncio.run(_run())
    except KeyboardInterrupt:  # pragma: no cover - interactive Ctrl-C
        console.print("\n[dim]stopped[/dim]")
    except SearchError as exc:
        _die(str(exc), code=2)


if __name__ == "__main__":  # pragma: no cover
    app()
