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
    node: str | None = None


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
    node: str = typer.Option(
        None,
        "--node",
        help="HA mode only: target a specific node (server/primary/secondary) by tofu `hosts`, bypassing the default origin resolution",
    ),
):
    """AdGuard Home verification CLI."""
    ctx.obj = Options(cluster, server_url, user, password, as_json, timeout, node)


def resolve(opts: Options) -> Ctx:
    if opts.node and not opts.server_url:
        tofu_json = dc.run_tofu_output(dc.default_chdir(opts.cluster))
        hosts = dc.parse_hosts(tofu_json)
        if opts.node not in hosts:
            _die(f"--node {opts.node!r} not in tofu hosts output: {sorted(hosts)}")
        target = dc.Target(base_url=f"http://{hosts[opts.node]['ipv4']}:{PORT}")
    else:
        # Default: the AdGuard web API/config edits must hit the ORIGIN node, never the VIP
        # (the "edit only on primary" rule — see specs/ha-dns.md). In single mode
        # dns_rewrite_target == the server VM's IP, so this is a no-op there.
        target = dc.resolve_target(
            port=PORT,
            cluster=opts.cluster,
            server_url=opts.server_url,
            url_env="ADGUARD_URL",
            target_output="dns_rewrite_target",
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


def _post(c: Ctx, path: str, json_body: dict[str, str]):
    """POST to /control, mirroring _get. AdGuard's write endpoints reply 200 with an empty body."""
    import httpx

    client = c.client()  # already logged in; do NOT reopen with `with`
    try:
        resp = client.post(path, json=json_body)
        resp.raise_for_status()
        return resp.json() if resp.content else {}
    except httpx.HTTPError as exc:
        _die(f"POST {path} failed: {exc}")
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


# --- DNS rewrites (custom hostname -> IP records) ----------------------------


def _rewrite_list(c: Ctx):
    """Current AdGuard rewrites as a list of {"domain","answer"} rows."""
    return _get(c, "/rewrite/list") or []


def _apply_rewrite_set(
    c: Ctx, domain: str, answer: str, rows: list[dict[str, str]]
) -> tuple[str, list[str]]:
    """Idempotently ensure a single domain->answer rewrite exists.

    `rows` is a snapshot of the current rewrite list (from `_rewrite_list`). AdGuard's
    /rewrite/add is additive (allows duplicate rows), so a real "set" must delete every
    existing row for the domain first. Returns (status, previous_answers) where status is
    one of unchanged/updated/added. Does not mutate `rows`; the caller refreshes its view.
    """
    existing = [r for r in rows if r.get("domain") == domain]
    old_answers = [str(r.get("answer", "")) for r in existing]
    if len(existing) == 1 and existing[0].get("answer") == answer:
        return "unchanged", old_answers
    for prev in old_answers:
        _post(c, "/rewrite/delete", {"domain": domain, "answer": prev})
    _post(c, "/rewrite/add", {"domain": domain, "answer": answer})
    return ("updated" if existing else "added"), old_answers


@app.command(name="rewrite-list")
def rewrite_list_cmd(ctx: typer.Context):
    """List custom DNS rewrites (GET /control/rewrite/list)."""
    c = resolve(ctx.obj)
    _emit(c, _rewrite_list(c), title="adguard rewrites")


@app.command(name="rewrite-add")
def rewrite_add(
    ctx: typer.Context,
    domain: str = typer.Argument(..., help="hostname, e.g. grafana.lab.example.com"),
    answer: str = typer.Argument(..., help="A-record IP the hostname resolves to"),
):
    """Add a rewrite (POST /control/rewrite/add). Additive — allows duplicates."""
    c = resolve(ctx.obj)
    _post(c, "/rewrite/add", {"domain": domain, "answer": answer})
    _emit(c, {"domain": domain, "answer": answer, "status": "added"})


@app.command(name="rewrite-delete")
def rewrite_delete(
    ctx: typer.Context,
    domain: str = typer.Argument(..., help="hostname to remove"),
    answer: str = typer.Argument(..., help="the A-record IP of the row to remove"),
):
    """Delete a rewrite (POST /control/rewrite/delete)."""
    c = resolve(ctx.obj)
    _post(c, "/rewrite/delete", {"domain": domain, "answer": answer})
    _emit(c, {"domain": domain, "answer": answer, "status": "deleted"})


@app.command(name="rewrite-set")
def rewrite_set(
    ctx: typer.Context,
    domain: str = typer.Argument(..., help="hostname"),
    answer: str = typer.Argument(..., help="A-record IP"),
):
    """Idempotently set a hostname->IP rewrite (delete any existing rows, then add)."""
    c = resolve(ctx.obj)
    rows = _rewrite_list(c)
    status, previous = _apply_rewrite_set(c, domain, answer, rows)
    _emit(
        c, {"domain": domain, "answer": answer, "status": status, "previous": previous}
    )


@app.command(name="rewrite-sync")
def rewrite_sync(
    ctx: typer.Context,
    file: str = typer.Option(
        ..., "--file", help="JSON object {hostname: answer}; '-' reads stdin"
    ),
    prune: bool = typer.Option(
        False, "--prune", help="also delete AdGuard rewrites not present in the payload"
    ),
):
    """Idempotently sync a batch of hostname->IP rewrites from a JSON object.

    Reads {"grafana.lab.example.com": "10.0.0.5", ...} from --file (or stdin via '-') and
    applies rewrite-set for each entry. Re-running is safe: unchanged rows are left alone,
    changed IPs overwrite the old answer. With --prune, rewrites whose domain is absent from
    the payload are removed (default off, so unmanaged rows are preserved).
    """
    import json
    import sys
    from pathlib import Path

    c = resolve(ctx.obj)
    raw = sys.stdin.read() if file == "-" else Path(file).read_text()
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        _die(f"--file is not valid JSON: {exc}")
    if not isinstance(payload, dict):
        _die("--file must be a JSON object of {hostname: answer}")

    rows = _rewrite_list(c)
    results: dict[str, list[str]] = {
        "added": [],
        "updated": [],
        "unchanged": [],
        "pruned": [],
    }
    for domain, answer in payload.items():
        status, _prev = _apply_rewrite_set(c, domain, str(answer), rows)
        results[status].append(domain)

    if prune:
        keep = set(payload.keys())
        for row in rows:
            dom = row.get("domain")
            if dom and dom not in keep:
                _post(
                    c,
                    "/rewrite/delete",
                    {"domain": dom, "answer": str(row.get("answer", ""))},
                )
                results["pruned"].append(dom)

    if c.as_json:
        dc.print_json(results)
    else:
        summary = {k: len(v) for k, v in results.items()}
        _emit(c, summary, title="adguard rewrite-sync")


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

    # 3. HA mode only: every node must independently answer, and the VIP itself must answer DNS
    # (not just be assigned) — see specs/ha-dns.md's failover acceptance criteria.
    if not ctx.obj.server_url:
        tofu_json = dc.run_tofu_output(dc.default_chdir(ctx.obj.cluster))
        if dc.is_ha(tofu_json):
            import httpx as _httpx

            for role, info in dc.parse_hosts(tofu_json).items():
                ip = info["ipv4"]
                try:
                    resp = _httpx.get(
                        f"http://{ip}:{PORT}/control/status",
                        timeout=c.timeout,
                        auth=_httpx.BasicAuth(c.user, c.password),
                    )
                    ok = resp.status_code < 400
                    detail = f"http://{ip}:{PORT}"
                except _httpx.HTTPError as exc:
                    ok, detail = False, str(exc)
                report.add(f"{role} answers /status", ok, detail)

            vip = tofu_json["dns_endpoint"]["value"]
            import subprocess

            dig = subprocess.run(
                ["dig", "+time=2", "+tries=1", "+short", f"@{vip}", "example.com"],
                capture_output=True,
                text=True,
            )
            report.add("VIP answers DNS", bool(dig.stdout.strip()), f"@{vip}")

    _render(c, report)
    raise typer.Exit(report.exit_code)


# --- HA: AdGuardHome-Sync status (primary only) ------------------------------


@app.command(name="sync-status")
def sync_status(
    ctx: typer.Context,
    lines: int = typer.Option(20, "--lines", help="journal lines to show"),
):
    """AdGuardHome-Sync status on primary — recent journal lines over SSH (HA mode only).

    adguardhome-sync doesn't expose an HTTP status endpoint in this deployment, so this shells
    to `journalctl -u adguardhome-sync` on primary (same SSH idiom as the rest of the repo's
    live-provisioning tooling — see CLAUDE.md).
    """
    import os
    import subprocess
    from pathlib import Path

    opts: Options = ctx.obj
    tofu_json = dc.run_tofu_output(dc.default_chdir(opts.cluster))
    if not dc.is_ha(tofu_json):
        _die("sync-status is only meaningful in HA mode (enable_ha=true)")

    primary_ip = dc.parse_hosts(tofu_json)["primary"]["ipv4"]
    ssh_key = os.environ.get(
        "CLUSTER_SSH_KEY", str(Path.home() / ".ssh" / "id_ed25519")
    )
    result = subprocess.run(
        [
            "ssh",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "UserKnownHostsFile=/dev/null",
            "-o",
            "LogLevel=ERROR",
            "-o",
            "ConnectTimeout=8",
            "-i",
            ssh_key,
            f"ubuntu@{primary_ip}",
            f"sudo systemctl is-active adguardhome-sync; sudo journalctl -u adguardhome-sync -n {lines} --no-pager",
        ],  # fmt: skip
        capture_output=True,
        text=True,
    )
    if opts.as_json:
        dc.print_json(
            {
                "host": primary_ip,
                "returncode": result.returncode,
                "stdout": result.stdout,
                "stderr": result.stderr,
            }
        )
    else:
        console.print(f"[bold]adguardhome-sync @ {primary_ip}[/bold]")
        console.print(result.stdout or result.stderr)
    raise typer.Exit(0 if result.returncode == 0 else dc.CHECK_FAIL_EXIT)


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
