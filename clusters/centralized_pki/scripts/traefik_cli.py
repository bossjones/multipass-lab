#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "typer>=0.12",
#     "rich>=13",
#     "pyyaml>=6",
# ]
# ///
"""traefik_cli — discover fleet-wide reverse-proxy routes and hot-push them into
centralized_pki's Traefik (the fleet-edge; see specs/dynamic-traefik.md).

Every cluster with a main.tf may publish a `reverse_proxy_routes` output (host/ip/port/scheme/
sso/k0s). This CLI aggregates that contract across `clusters/*/`, renders one Traefik dynamic-config
document (`fleet.yaml`), and — via `sync` — installs it onto the running pki services VM's watched
directory (`/opt/stack/traefik/dynamic/`). Traefik's file provider (`directory` + `watch: true`)
hot-reloads it: no VM recreate, no container restart.

pki's OWN routes (auth./warden.) are deliberately excluded from the rendered routers — they are
already served directly by the untouched `dynamic.yaml`; re-declaring them in `fleet.yaml` would
create a second router for the same Host() rule Traefik already owns. They still appear in
`targets`/`render --json` for contract completeness.

    uv run traefik_cli.py targets                 # print resolved fleet routes (no push)
    uv run traefik_cli.py render                   # write .rendered/fleet.yaml locally (no push)
    uv run traefik_cli.py sync                     # render + scp + install (no restart)
    uv run traefik_cli.py check                    # render + probe every backend; exit nonzero on failure
    uv run traefik_cli.py hosts                    # print an /etc/hosts block (laptops not using AdGuard)
"""

from __future__ import annotations

import http.client
import os
import ssl
import subprocess
from dataclasses import dataclass
from pathlib import Path

import _pki_common as pc
import typer
import yaml
from rich.console import Console
from rich.table import Table

app = typer.Typer(add_completion=False, no_args_is_help=True, help=__doc__)
console = Console()

# Hosts pki's own dynamic.yaml already routes directly — never re-declared as fleet.yaml routers
# (would create a duplicate/self-looping router for a Host() rule Traefik already owns).
RESERVED_HOSTS = frozenset({"auth", "warden"})

SSH_OPTS = [
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "LogLevel=ERROR",
    "-o", "ConnectTimeout=8",
]


def _ssh_key() -> str:
    return os.environ.get("CLUSTER_SSH_KEY", str(Path.home() / ".ssh" / "id_ed25519"))


@dataclass
class Options:
    pki_cluster: str
    as_json: bool
    timeout: float
    pki_ip: str | None = None
    domain: str | None = None


@app.callback()
def _main(
    ctx: typer.Context,
    cluster: str = typer.Option("centralized_pki", "--cluster", help="pki cluster dir (holds the fleet edge)"),
    as_json: bool = typer.Option(False, "--json"),
    timeout: float = typer.Option(10.0, "--timeout"),
    pki_ip: str = typer.Option(None, "--pki-ip", help="override pki services VM IP (skip tofu output)"),
    domain: str = typer.Option(None, "--domain", help="override the fleet domain (skip tofu output)"),
):
    """Fleet-edge Traefik discovery + hot-push CLI."""
    ctx.obj = Options(cluster, as_json, timeout, pki_ip, domain)


def _die(msg: str, code: int = 1):
    console.print(f"[red]error:[/red] {msg}")
    raise typer.Exit(code)


# --- discovery -----------------------------------------------------------------


def discover_routes(clusters_root: Path, runner=pc.run_tofu_output) -> list[dict]:
    """Aggregate `reverse_proxy_routes` across every `clusters/*/` with a main.tf.

    A cluster that isn't applied (or has no such output) contributes nothing — tolerated, not
    fatal. Each returned route dict gains a `_cluster` key naming its source cluster dir.
    """
    routes: list[dict] = []
    for cluster_dir in sorted(clusters_root.iterdir()):
        if not (cluster_dir / "main.tf").is_file():
            continue
        try:
            tofu_json = runner(str(cluster_dir))
        except (subprocess.CalledProcessError, FileNotFoundError):
            continue
        raw = tofu_json.get("reverse_proxy_routes", {}).get("value") or []
        for route in raw:
            routes.append({**route, "_cluster": cluster_dir.name})
    return routes


def resolve_domain(cluster: str, override: str | None, runner=pc.run_tofu_output) -> str:
    if override:
        return override
    tofu_json = runner(pc.default_chdir(cluster))
    domain = tofu_json.get("domain", {}).get("value")
    if not domain:
        _die(f"no `domain` output from {cluster} (is it up?)")
    return domain


def resolve_pki_ip(cluster: str, override: str | None, runner=pc.run_tofu_output) -> str:
    if override:
        return override
    tofu_json = runner(pc.default_chdir(cluster))
    ip = tofu_json.get("services_ipv4", {}).get("value")
    if not ip:
        _die(f"no `services_ipv4` output from {cluster} (is it up?)")
    return ip


# --- render ----------------------------------------------------------------------


def render_fleet(routes: list[dict], domain: str, *, skip_hosts: frozenset[str] = RESERVED_HOSTS) -> str:
    """Render a Traefik dynamic-config YAML document from discovered routes.

    One router + service per route (skipping `skip_hosts`), the `authelia` forward-auth
    middleware attached when `sso`, and — for a k0s route whose target port is NOT in the
    Kubernetes NodePort range (30000-32767) — a Host-rewrite headers middleware + disabled
    passHostHeader, so an ingress-nginx backend (which routes by Host) resolves instead of 404ing.
    A NodePort target (the recommended, simplest k0s shape) needs no such rewrite.
    """
    routers: dict = {}
    services: dict = {}
    middlewares: dict = {}
    claimed: dict[str, str] = {}

    for route in routes:
        host = route["host"]
        if host in skip_hosts:
            continue
        if host in claimed:
            raise ValueError(
                f"duplicate fleet route host {host!r}: claimed by both "
                f"{claimed[host]!r} and {route.get('_cluster', '?')!r}"
            )
        claimed[host] = route.get("_cluster", "?")

        name = f"fleet-{host}"
        router = {
            "rule": f"Host(`{host}.{domain}`)",
            "entryPoints": ["websecure"],
            "service": name,
            "tls": {},
        }
        service = {"loadBalancer": {"servers": [{"url": f"{route['scheme']}://{route['ip']}:{route['port']}"}]}}

        router_middlewares = []
        if route.get("sso"):
            router_middlewares.append("authelia")
        if route.get("k0s") and route.get("k0s_ingress_host") and int(route["port"]) < 30000:
            mw_name = f"{name}-host"
            middlewares[mw_name] = {"headers": {"customRequestHeaders": {"Host": route["k0s_ingress_host"]}}}
            router_middlewares.append(mw_name)
            service["loadBalancer"]["passHostHeader"] = False
        if router_middlewares:
            router["middlewares"] = router_middlewares

        routers[name] = router
        services[name] = service

    doc: dict = {"http": {"routers": routers, "services": services}}
    if middlewares:
        doc["http"]["middlewares"] = middlewares
    return yaml.safe_dump(doc, sort_keys=True)


# --- probe (used by `check`; stdlib http.client so it's trivially testable) -----------------


def probe_route(*, ip: str, port: int, scheme: str, host_header: str, timeout: float) -> tuple[bool, str]:
    """GET `/` at ip:port with a Host header override. Returns (ok, detail). ok = non-5xx."""
    try:
        if scheme == "https":
            conn = http.client.HTTPSConnection(ip, port, timeout=timeout, context=ssl._create_unverified_context())
        else:
            conn = http.client.HTTPConnection(ip, port, timeout=timeout)
        try:
            conn.request("GET", "/", headers={"Host": host_header})
            resp = conn.getresponse()
            resp.read()
            return resp.status < 500, f"HTTP {resp.status}"
        finally:
            conn.close()
    except (OSError, ssl.SSLError) as exc:
        return False, f"connection error: {exc}"


# --- commands ----------------------------------------------------------------------


@app.command()
def targets(ctx: typer.Context):
    """Print the resolved fleet routes (no push)."""
    o: Options = ctx.obj
    routes = discover_routes(pc.CLUSTERS_ROOT)
    if o.as_json:
        pc.print_json(routes)
        return
    table = Table("host", "cluster", "ip", "port", "scheme", "sso", "k0s", title="fleet-edge routes")
    for r in routes:
        table.add_row(
            r["host"], r.get("_cluster", ""), r["ip"], str(r["port"]), r["scheme"],
            str(r.get("sso", False)), str(r.get("k0s", False)),
        )
    console.print(table)


@app.command()
def render(ctx: typer.Context, out: str = typer.Option(None, "--out", help="write path (default: <pki-cluster>/.rendered/fleet.yaml)")):
    """Render fleet.yaml locally (no push)."""
    o: Options = ctx.obj
    domain = resolve_domain(o.pki_cluster, o.domain)
    routes = discover_routes(pc.CLUSTERS_ROOT)
    doc = render_fleet(routes, domain)
    out_path = Path(out) if out else pc.CLUSTERS_ROOT / o.pki_cluster / ".rendered" / "fleet.yaml"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(doc)
    if o.as_json:
        pc.print_json({"path": str(out_path), "routes": len(routes)})
    else:
        console.print(f"[green]wrote[/green] {out_path} ({len(routes)} routes discovered)")


@app.command()
def sync(ctx: typer.Context):
    """Render + scp + install fleet.yaml onto the running pki services VM. No restart — Traefik's file-watch reloads it."""
    o: Options = ctx.obj
    domain = resolve_domain(o.pki_cluster, o.domain)
    pki_ip = resolve_pki_ip(o.pki_cluster, o.pki_ip)
    routes = discover_routes(pc.CLUSTERS_ROOT)
    doc = render_fleet(routes, domain)

    rendered = pc.CLUSTERS_ROOT / o.pki_cluster / ".rendered" / "fleet.yaml"
    rendered.parent.mkdir(parents=True, exist_ok=True)
    rendered.write_text(doc)

    key = _ssh_key()
    subprocess.run(
        ["scp", *SSH_OPTS, "-i", key, str(rendered), f"ubuntu@{pki_ip}:/tmp/fleet.yaml"],
        check=True,
    )
    subprocess.run(
        ["ssh", "-n", *SSH_OPTS, "-i", key, f"ubuntu@{pki_ip}",
         "sudo cp /tmp/fleet.yaml /opt/stack/traefik/dynamic/fleet.yaml"],
        check=True,
    )
    if o.as_json:
        pc.print_json({"pki_ip": pki_ip, "routes": len(routes)})
    else:
        console.print(f"[green]synced[/green] {len(routes)} routes to {pki_ip} (no restart — file-watch reloads)")


@app.command()
def check(ctx: typer.Context):
    """Render, then probe every route's backend through the edge; exit nonzero on any failure."""
    o: Options = ctx.obj
    domain = resolve_domain(o.pki_cluster, o.domain)
    pki_ip = resolve_pki_ip(o.pki_cluster, o.pki_ip)
    routes = discover_routes(pc.CLUSTERS_ROOT)
    try:
        render_fleet(routes, domain)  # validates (raises on duplicate hosts) before probing
    except ValueError as exc:
        _die(str(exc))

    report = pc.CheckReport()
    for route in routes:
        host = route["host"]
        if host in RESERVED_HOSTS:
            report.skip(host, "served directly by pki's dynamic.yaml, not the fleet edge")
            continue
        ok, detail = probe_route(
            ip=pki_ip, port=443, scheme="https",
            host_header=f"{host}.{domain}", timeout=o.timeout,
        )
        report.add(host, ok, detail)

    if o.as_json:
        pc.print_json(report.to_dict())
    else:
        table = Table("route", "status", "detail", title="traefik-check")
        colors = {"pass": "green", "fail": "red", "skip": "yellow"}
        for chk in report.checks:
            color = colors[chk.status]
            table.add_row(chk.name, f"[{color}]{chk.status}[/{color}]", chk.detail)
        console.print(table)
        console.print(f"[{'green' if report.passed else 'red'}]{'PASS' if report.passed else 'FAIL'}[/]")
    raise typer.Exit(report.exit_code)


@app.command()
def hosts(ctx: typer.Context):
    """Print an /etc/hosts block mapping every fleet route to the pki edge IP (for laptops not using AdGuard)."""
    o: Options = ctx.obj
    domain = resolve_domain(o.pki_cluster, o.domain)
    pki_ip = resolve_pki_ip(o.pki_cluster, o.pki_ip)
    routes = discover_routes(pc.CLUSTERS_ROOT)
    names = sorted({r["host"] for r in routes if r["host"] not in RESERVED_HOSTS})
    lines = [f"{pki_ip} {name}.{domain}" for name in names]
    if o.as_json:
        pc.print_json({"pki_ip": pki_ip, "lines": lines})
    else:
        for line in lines:
            console.print(line)


@app.command(name="dns-rewrites")
def dns_rewrites(ctx: typer.Context):
    """Emit {"<host>.<domain>": pki_ip} for every fleet-fronted route, for AdGuard rewrite-sync.

    A cluster onboarded to the fleet edge (its `reverse_proxy_routes` claims a host) should
    resolve that hostname to pki's Traefik, not to its own IP — `just set-dns-all` layers this
    mapping OVER the raw per-cluster `dns_records` so the fleet edge wins for onboarded hosts,
    while everything else keeps resolving directly. Best-effort: prints {} (exit 0) if pki isn't
    up yet, so this can be folded into DNS registration even before centralized_pki exists.
    """
    o: Options = ctx.obj
    try:
        domain = resolve_domain(o.pki_cluster, o.domain)
        pki_ip = resolve_pki_ip(o.pki_cluster, o.pki_ip)
    except typer.Exit:
        pc.print_json({})
        return
    routes = discover_routes(pc.CLUSTERS_ROOT)
    mapping = {f"{r['host']}.{domain}": pki_ip for r in routes if r["host"] not in RESERVED_HOSTS}
    pc.print_json(mapping)


if __name__ == "__main__":
    app()
