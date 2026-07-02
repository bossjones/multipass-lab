#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "typer>=0.12",
#     "rich>=13",
#     "pynetbox>=7.3",
#     "httpx>=0.27",
#     "requests>=2.31",
# ]
# ///
"""netbox_cli — verify & introspect the cluster's NetBox over its REST API.

Uses the official `pynetbox` SDK for object queries and raw `httpx` for the unauthenticated
`/api/status/` health probe. Introspection (rich tables or `--json`) plus a CI-friendly `check`
that asserts NetBox is healthy, the token authenticates, and the client VM self-registered with a
primary IP. Resolves the server URL + token from `tofu output` (or `--server-url` / `--token`).
See specs/cli-netbox.md.

    uv run netbox_cli.py check --cluster centralized_netbox
    uv run netbox_cli.py vms --json
"""

from __future__ import annotations

import os
from dataclasses import dataclass

import _obs_common as oc
import typer
from rich.console import Console
from rich.table import Table

PORT = 8000
DEFAULT_CLUSTER_NAME = "centralized-netbox"
DEFAULT_VM_NAME = "centralized-netbox-client"
DEFAULT_SITE_NAME = "multipass-lab"

app = typer.Typer(add_completion=False, no_args_is_help=True, help=__doc__)
console = Console()


@dataclass
class Options:
    cluster: str
    server_url: str | None
    token: str | None
    cluster_name: str | None
    vm_name: str | None
    site_name: str | None
    as_json: bool
    timeout: float
    insecure: bool


@dataclass
class Ctx:
    base_url: str
    token: str | None
    cluster_name: str
    vm_name: str
    site_name: str
    as_json: bool
    timeout: float
    insecure: bool

    def nb(self):
        import pynetbox
        import requests

        api = pynetbox.api(self.base_url, token=self.token or "")
        session = requests.Session()
        session.verify = not self.insecure
        api.http_session = session
        return api


@app.callback()
def _main(
    ctx: typer.Context,
    cluster: str = typer.Option("centralized_netbox", "--cluster"),
    server_url: str = typer.Option(None, "--server-url", help="override; else tofu output"),
    token: str = typer.Option(None, "--token", help="API token; else $NETBOX_TOKEN / tofu output"),
    cluster_name: str = typer.Option(
        None, "--cluster-name", help="virtualization cluster to assert (else tofu / default)"
    ),
    vm_name: str = typer.Option(
        None, "--vm-name", help="expected self-registered VM (else tofu / default)"
    ),
    site_name: str = typer.Option(
        None, "--site-name", help="expected default DCIM site (else tofu / default)"
    ),
    as_json: bool = typer.Option(False, "--json", help="machine-readable JSON output"),
    timeout: float = typer.Option(10.0, "--timeout"),
    insecure: bool = typer.Option(False, "--insecure"),
):
    """NetBox verification CLI."""
    ctx.obj = Options(
        cluster, server_url, token, cluster_name, vm_name, site_name, as_json, timeout, insecure
    )


def resolve(opts: Options) -> Ctx:
    base_url = opts.server_url or os.environ.get("NETBOX_URL")
    token = opts.token or os.environ.get("NETBOX_TOKEN")
    cluster_name = opts.cluster_name
    vm_name = opts.vm_name
    site_name = opts.site_name

    # tofu mode: no explicit URL -> resolve everything from `tofu output -json`.
    if base_url is None:
        doc = oc.run_tofu_output(oc.default_chdir(opts.cluster))

        def val(key, default=None):
            return doc.get(key, {}).get("value", default)

        ip = val("server_ipv4")
        base_url = val("netbox_url") or (f"http://{ip}:{PORT}" if ip else None)
        token = token or val("netbox_api_token")
        cluster_name = cluster_name or val("netbox_cluster_name")
        vm_name = vm_name or val("registered_vm_name")
        site_name = site_name or val("netbox_site_name")

    if base_url is None:
        _die("could not resolve NetBox URL — pass --server-url or run from a cluster dir")

    return Ctx(
        base_url=base_url.rstrip("/"),
        token=token,
        cluster_name=cluster_name or DEFAULT_CLUSTER_NAME,
        vm_name=vm_name or DEFAULT_VM_NAME,
        site_name=site_name or DEFAULT_SITE_NAME,
        as_json=opts.as_json,
        timeout=opts.timeout,
        insecure=opts.insecure,
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


# --- introspection commands --------------------------------------------------


def _status_headers(c: Ctx) -> dict:
    # NetBox may require auth even for /api/status/, so send the token when we have one.
    return {"Authorization": f"Token {c.token}"} if c.token else {}


@app.command()
def status(ctx: typer.Context):
    """NetBox health + versions (GET /api/status/)."""
    c = resolve(ctx.obj)
    import httpx

    try:
        resp = httpx.get(
            f"{c.base_url}/api/status/",
            headers=_status_headers(c),
            timeout=c.timeout,
            verify=not c.insecure,
        )
        resp.raise_for_status()
        data = resp.json()
    except httpx.HTTPError as exc:
        _die(f"netbox unreachable: {exc}")
    _emit(c, data, title="netbox status")


@app.command()
def clusters(ctx: typer.Context):
    """List virtualization clusters (GET /api/virtualization/clusters/)."""
    c = resolve(ctx.obj)
    try:
        rows = [
            {"id": cl.id, "name": str(cl.name), "type": str(cl.type)}
            for cl in c.nb().virtualization.clusters.all()
        ]
    except Exception as exc:  # noqa: BLE001 - surface any API/auth error as a clean message
        _die(f"could not list clusters: {exc}")
    _emit(c, rows, title="virtualization clusters")


@app.command()
def vms(ctx: typer.Context):
    """List virtual machines (GET /api/virtualization/virtual-machines/)."""
    c = resolve(ctx.obj)
    try:
        rows = [
            {
                "id": vm.id,
                "name": str(vm.name),
                "status": str(vm.status),
                "cluster": str(vm.cluster),
                "primary_ip": str(vm.primary_ip4) if vm.primary_ip4 else "",
            }
            for vm in c.nb().virtualization.virtual_machines.all()
        ]
    except Exception as exc:  # noqa: BLE001
        _die(f"could not list virtual machines: {exc}")
    _emit(c, rows, title="virtual machines")


# --- check -------------------------------------------------------------------


@app.command()
def check(ctx: typer.Context):
    """Assert NetBox health + auth + the client self-registered; exit nonzero on failure."""
    c = resolve(ctx.obj)
    import httpx

    report = oc.CheckReport()

    # 1. NetBox reachable (/api/status/). Short-circuit if the server is down.
    try:
        resp = httpx.get(
            f"{c.base_url}/api/status/",
            headers=_status_headers(c),
            timeout=c.timeout,
            verify=not c.insecure,
        )
        report.add("netbox reachable", resp.status_code == 200, f"status={resp.status_code}")
        if resp.status_code != 200:
            _render_check(c, report)
            raise typer.Exit(report.exit_code)
    except httpx.HTTPError as exc:
        report.add("netbox reachable", False, str(exc))
        _render_check(c, report)
        raise typer.Exit(report.exit_code)

    # 2/3/4. Token authenticates + the bootstrapped cluster + default DCIM site exist.
    nb = c.nb()
    try:
        clusters = list(nb.virtualization.clusters.filter(name=c.cluster_name))
        report.add("token authenticates", True, "authenticated read succeeded")
        report.add("cluster present", len(clusters) >= 1, c.cluster_name)
        # NetBox requires a site before any device; the bootstrap seeds a default one.
        sites = list(nb.dcim.sites.filter(name=c.site_name))
        report.add("site present", len(sites) >= 1, c.site_name)
    except Exception as exc:  # noqa: BLE001 - pynetbox raises on 401/403/transport errors
        report.add("token authenticates", False, str(exc))
        report.skip("cluster present", "auth failed")
        report.skip("site present", "auth failed")

    # 4/5. The client VM registered itself, active, with a primary IP.
    vm = None
    try:
        matches = list(nb.virtualization.virtual_machines.filter(name=c.vm_name))
        vm = matches[0] if matches else None
    except Exception as exc:  # noqa: BLE001
        report.add("client vm registered", False, str(exc))

    if vm is not None:
        active = getattr(vm.status, "value", str(vm.status)) == "active"
        report.add("client vm registered", active, f"{c.vm_name} status={vm.status}")
        report.add(
            "primary ip assigned",
            vm.primary_ip4 is not None,
            str(vm.primary_ip4) if vm.primary_ip4 else "none",
        )
    elif "client vm registered" not in {chk.name for chk in report.checks}:
        report.add("client vm registered", False, f"{c.vm_name} not found")
        report.skip("primary ip assigned", "vm missing")

    _render_check(c, report)
    raise typer.Exit(report.exit_code)


def _render_check(c: Ctx, report: oc.CheckReport):
    if c.as_json:
        oc.print_json(report.to_dict())
        return
    table = Table("check", "status", "detail", title="netbox check")
    colors = {"pass": "green", "fail": "red", "skip": "yellow"}
    for chk in report.checks:
        color = colors[chk.status]
        table.add_row(chk.name, f"[{color}]{chk.status}[/{color}]", chk.detail)
    console.print(table)
    verdict = "PASS" if report.passed else "FAIL"
    console.print(f"[{'green' if report.passed else 'red'}]{verdict}[/]")


if __name__ == "__main__":
    app()
