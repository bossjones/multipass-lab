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
DEFAULT_HOST_DEVICE = "multipass-host"
DEFAULT_RACK_NAME = "multipass-rack-1"

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
    host_device_name: str | None
    rack_name: str | None
    prefix: str | None
    discovery: bool
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
    host_device_name: str
    rack_name: str
    prefix: str | None
    discovery_enabled: bool
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
    host_device_name: str = typer.Option(
        None, "--host-device", help="expected host DCIM device (else tofu / default)"
    ),
    rack_name: str = typer.Option(
        None, "--rack", help="expected DCIM rack (else tofu / default)"
    ),
    prefix: str = typer.Option(
        None, "--prefix", help="expected IPAM prefix (else tofu; any prefix if unresolved)"
    ),
    discovery: bool = typer.Option(
        False, "--discovery", help="assert the opt-in Diode/orb-agent footprint (plugin + discovered IPs); else resolved from tofu output"
    ),
    as_json: bool = typer.Option(False, "--json", help="machine-readable JSON output"),
    timeout: float = typer.Option(10.0, "--timeout"),
    insecure: bool = typer.Option(False, "--insecure"),
):
    """NetBox verification CLI."""
    ctx.obj = Options(
        cluster, server_url, token, cluster_name, vm_name, site_name,
        host_device_name, rack_name, prefix, discovery, as_json, timeout, insecure,
    )


def resolve(opts: Options) -> Ctx:
    base_url = opts.server_url or os.environ.get("NETBOX_URL")
    token = opts.token or os.environ.get("NETBOX_TOKEN")
    cluster_name = opts.cluster_name
    vm_name = opts.vm_name
    site_name = opts.site_name
    host_device_name = opts.host_device_name
    rack_name = opts.rack_name
    prefix = opts.prefix
    discovery_enabled = opts.discovery

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
        host_device_name = host_device_name or val("netbox_host_device_name")
        rack_name = rack_name or val("netbox_rack_name")
        prefix = prefix or val("netbox_prefix")
        # --discovery forces the assertions on; otherwise follow the deployed footprint.
        discovery_enabled = discovery_enabled or bool(val("discovery_enabled"))

    if base_url is None:
        _die("could not resolve NetBox URL — pass --server-url or run from a cluster dir")

    return Ctx(
        base_url=base_url.rstrip("/"),
        token=token,
        cluster_name=cluster_name or DEFAULT_CLUSTER_NAME,
        vm_name=vm_name or DEFAULT_VM_NAME,
        site_name=site_name or DEFAULT_SITE_NAME,
        host_device_name=host_device_name or DEFAULT_HOST_DEVICE,
        rack_name=rack_name or DEFAULT_RACK_NAME,
        prefix=prefix or None,
        discovery_enabled=discovery_enabled,
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


@app.command()
def devices(ctx: typer.Context):
    """List DCIM devices (GET /api/dcim/devices/) — the physical host lives here, not VMs."""
    c = resolve(ctx.obj)
    try:
        rows = [
            {
                "id": d.id,
                "name": str(d.name),
                "role": str(d.role),
                "site": str(d.site),
                "rack": str(d.rack) if d.rack else "",
                "status": str(d.status),
            }
            for d in c.nb().dcim.devices.all()
        ]
    except Exception as exc:  # noqa: BLE001
        _die(f"could not list devices: {exc}")
    _emit(c, rows, title="dcim devices")


@app.command()
def prefixes(ctx: typer.Context):
    """List IPAM prefixes (GET /api/ipam/prefixes/)."""
    c = resolve(ctx.obj)
    try:
        rows = [
            {
                "id": p.id,
                "prefix": str(p.prefix),
                "site": str(p.site) if p.site else "",
                "vlan": str(p.vlan) if p.vlan else "",
                "status": str(p.status),
            }
            for p in c.nb().ipam.prefixes.all()
        ]
    except Exception as exc:  # noqa: BLE001
        _die(f"could not list prefixes: {exc}")
    _emit(c, rows, title="ipam prefixes")


# NetBox reports installed plugins in /api/status/ under "plugins": {name: version}.
DIODE_PLUGIN = "netbox_diode_plugin"


@app.command()
def discovery(ctx: typer.Context):
    """Discovery footprint (opt-in): Diode plugin status + IP addresses (the discovered artifacts)."""
    c = resolve(ctx.obj)
    import httpx

    plugins = {}
    try:
        resp = httpx.get(
            f"{c.base_url}/api/status/",
            headers=_status_headers(c),
            timeout=c.timeout,
            verify=not c.insecure,
        )
        resp.raise_for_status()
        plugins = resp.json().get("plugins", {}) or {}
    except httpx.HTTPError as exc:
        _die(f"netbox unreachable: {exc}")

    try:
        ips = [
            {
                "address": str(ip.address),
                "assigned": str(ip.assigned_object) if ip.assigned_object else "",
                "status": str(ip.status),
            }
            for ip in c.nb().ipam.ip_addresses.all()
        ]
    except Exception as exc:  # noqa: BLE001
        _die(f"could not list ip addresses: {exc}")

    if c.as_json:
        oc.print_json(
            {"diode_plugin": plugins.get(DIODE_PLUGIN, "not installed"), "ip_count": len(ips), "ips": ips}
        )
        return
    _emit(
        c,
        {"diode_plugin": plugins.get(DIODE_PLUGIN, "not installed"), "ip_count": len(ips)},
        title="discovery",
    )
    _emit(c, ips, title="discovered ip addresses")


# --- check -------------------------------------------------------------------


@app.command()
def check(ctx: typer.Context):
    """Assert NetBox health + auth + the client self-registered; exit nonzero on failure."""
    c = resolve(ctx.obj)
    import httpx

    report = oc.CheckReport()
    status_json = {}

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
        try:
            status_json = resp.json()
        except ValueError:
            status_json = {}
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

    # 6-9. Base data model: DCIM library + rack + the host device (populates /dcim/devices/) +
    # a seeded IPAM prefix. See specs/netbox-data.md.
    try:
        n_mfr = len(list(nb.dcim.manufacturers.all()))
        n_dt = len(list(nb.dcim.device_types.all()))
        n_dr = len(list(nb.dcim.device_roles.all()))
        report.add(
            "device library seeded",
            n_mfr >= 1 and n_dt >= 1 and n_dr >= 1,
            f"manufacturers={n_mfr} device_types={n_dt} device_roles={n_dr}",
        )

        racks = list(nb.dcim.racks.filter(name=c.rack_name))
        report.add("rack present", len(racks) >= 1, c.rack_name)

        hosts = list(nb.dcim.devices.filter(name=c.host_device_name))
        host_active = bool(hosts) and getattr(hosts[0].status, "value", str(hosts[0].status)) == "active"
        report.add(
            "host device present",
            host_active,
            c.host_device_name if hosts else f"{c.host_device_name} not found",
        )

        if c.prefix:
            pfx = list(nb.ipam.prefixes.filter(prefix=c.prefix))
            report.add("prefix present", len(pfx) >= 1, c.prefix)
        else:
            n_pfx = len(list(nb.ipam.prefixes.all()))
            report.add("prefix present", n_pfx >= 1, f"count={n_pfx}")
    except Exception as exc:  # noqa: BLE001 - surface API/auth errors as a single failing row
        report.add("base data model", False, str(exc))

    # 10/11. Discovery (opt-in). When enabled, the Diode plugin must be installed and the agent must
    # have discovered at least one IP; when disabled these are skipped, not failed. See
    # specs/netbox-discovery.md.
    if c.discovery_enabled:
        plugins = (status_json or {}).get("plugins", {}) or {}
        report.add("diode plugin installed", DIODE_PLUGIN in plugins, plugins.get(DIODE_PLUGIN, "not installed"))
        try:
            n_ips = len(list(nb.ipam.ip_addresses.all()))
            report.add("discovered ips present", n_ips >= 1, f"count={n_ips}")
        except Exception as exc:  # noqa: BLE001
            report.add("discovered ips present", False, str(exc))
    else:
        report.skip("diode plugin installed", "discovery disabled")
        report.skip("discovered ips present", "discovery disabled")

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
