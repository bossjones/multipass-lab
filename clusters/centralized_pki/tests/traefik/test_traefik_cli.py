"""Hermetic behavior tests for traefik_cli (TDD).

render_fleet/probe_route are pure(-ish) functions fed fixed inputs — no tofu, no ssh, no network
egress except probe_route's real (loopback) socket tests. CLI-level tests monkeypatch discovery/
resolution so CliRunner never shells out.
"""

import json

import pytest
import traefik_cli as tc
import yaml
from typer.testing import CliRunner

runner = CliRunner()


def _run(*args):
    return runner.invoke(tc.app, list(args))


NETBOX_ROUTE = {"host": "netbox", "ip": "10.0.0.5", "port": 8000, "scheme": "http", "sso": False, "k0s": False, "_cluster": "centralized_netbox"}
PROM_ROUTE = {"host": "prom", "ip": "10.0.0.6", "port": 9090, "scheme": "http", "sso": True, "k0s": False, "_cluster": "centralized_monitoring"}
COROOT_NODEPORT = {"host": "coroot", "ip": "10.0.0.7", "port": 30080, "scheme": "http", "sso": False, "k0s": True, "k0s_ingress_host": "coroot.local", "_cluster": "centralized_logging"}
COROOT_INGRESS = {"host": "coroot", "ip": "10.0.0.7", "port": 80, "scheme": "http", "sso": False, "k0s": True, "k0s_ingress_host": "coroot.local", "_cluster": "centralized_logging"}
AUTH_ROUTE = {"host": "auth", "ip": "10.0.0.1", "port": 443, "scheme": "https", "sso": False, "k0s": False, "_cluster": "centralized_pki"}


# ---- render_fleet ----


def test_render_fleet_basic_route():
    doc = yaml.safe_load(tc.render_fleet([NETBOX_ROUTE], "lab.test"))
    assert doc["http"]["routers"]["fleet-netbox"]["rule"] == "Host(`netbox.lab.test`)"
    assert doc["http"]["services"]["fleet-netbox"]["loadBalancer"]["servers"] == [{"url": "http://10.0.0.5:8000"}]
    assert "middlewares" not in doc["http"]["routers"]["fleet-netbox"]


def test_render_fleet_skips_reserved_hosts():
    doc = yaml.safe_load(tc.render_fleet([AUTH_ROUTE, NETBOX_ROUTE], "lab.test"))
    assert "fleet-auth" not in doc["http"]["routers"]
    assert "fleet-netbox" in doc["http"]["routers"]


def test_render_fleet_sso_attaches_authelia_middleware():
    doc = yaml.safe_load(tc.render_fleet([PROM_ROUTE], "lab.test"))
    assert doc["http"]["routers"]["fleet-prom"]["middlewares"] == ["authelia"]


def test_render_fleet_k0s_nodeport_no_rewrite():
    """NodePort (port in the k8s NodePort range) needs no Host-rewrite middleware."""
    doc = yaml.safe_load(tc.render_fleet([COROOT_NODEPORT], "lab.test"))
    router = doc["http"]["routers"]["fleet-coroot"]
    assert "middlewares" not in router
    assert "passHostHeader" not in doc["http"]["services"]["fleet-coroot"]["loadBalancer"]


def test_render_fleet_k0s_ingress_adds_host_rewrite():
    """A k0s route through ingress-nginx (port outside the NodePort range) needs the Host rewrite."""
    doc = yaml.safe_load(tc.render_fleet([COROOT_INGRESS], "lab.test"))
    router = doc["http"]["routers"]["fleet-coroot"]
    assert router["middlewares"] == ["fleet-coroot-host"]
    assert doc["http"]["middlewares"]["fleet-coroot-host"]["headers"]["customRequestHeaders"]["Host"] == "coroot.local"
    assert doc["http"]["services"]["fleet-coroot"]["loadBalancer"]["passHostHeader"] is False


def test_render_fleet_duplicate_host_raises():
    dup = {**NETBOX_ROUTE, "_cluster": "centralized_other"}
    with pytest.raises(ValueError, match="duplicate fleet route host 'netbox'"):
        tc.render_fleet([NETBOX_ROUTE, dup], "lab.test")


def test_render_fleet_valid_yaml_with_no_routes():
    doc = yaml.safe_load(tc.render_fleet([], "lab.test"))
    assert doc == {"http": {"routers": {}, "services": {}}}


# ---- discover_routes ----


def test_discover_routes_aggregates_across_clusters_and_tolerates_failures(tmp_path):
    (tmp_path / "centralized_netbox").mkdir()
    (tmp_path / "centralized_netbox" / "main.tf").write_text("")
    (tmp_path / "centralized_broken").mkdir()
    (tmp_path / "centralized_broken" / "main.tf").write_text("")
    (tmp_path / "_shared").mkdir()  # no main.tf -> skipped

    def fake_runner(chdir):
        if "netbox" in chdir:
            return {"reverse_proxy_routes": {"value": [dict(NETBOX_ROUTE)]}}
        raise __import__("subprocess").CalledProcessError(1, "tofu")

    routes = tc.discover_routes(tmp_path, runner=fake_runner)
    assert len(routes) == 1
    assert routes[0]["host"] == "netbox"
    assert routes[0]["_cluster"] == "centralized_netbox"


def test_discover_routes_empty_when_no_clusters(tmp_path):
    assert tc.discover_routes(tmp_path, runner=lambda c: {}) == []


# ---- probe_route ----


def test_probe_route_passes_on_200(http_server):
    ip, port = http_server
    ok, detail = tc.probe_route(ip=ip, port=port, scheme="http", host_header="netbox.lab.test", timeout=2.0)
    assert ok is True
    assert "200" in detail


def test_probe_route_fails_on_503(http_server_503):
    ip, port = http_server_503
    ok, detail = tc.probe_route(ip=ip, port=port, scheme="http", host_header="netbox.lab.test", timeout=2.0)
    assert ok is False
    assert "503" in detail


def test_probe_route_fails_on_connection_refused():
    ok, detail = tc.probe_route(ip="127.0.0.1", port=1, scheme="http", host_header="x", timeout=1.0)
    assert ok is False
    assert "connection error" in detail


# ---- CLI commands (discovery/resolution monkeypatched — no tofu, no ssh) ----


@pytest.fixture
def patched(monkeypatch):
    monkeypatch.setattr(tc, "discover_routes", lambda *_a, **_k: [dict(NETBOX_ROUTE)])
    monkeypatch.setattr(tc, "resolve_domain", lambda *_a, **_k: "lab.test")
    monkeypatch.setattr(tc, "resolve_pki_ip", lambda *_a, **_k: "10.0.0.1")


def test_targets_json_lists_discovered_routes(patched):
    r = _run("--json", "targets")
    assert r.exit_code == 0, r.output
    data = json.loads(r.output)
    assert data[0]["host"] == "netbox"


def test_render_writes_fleet_yaml(patched, tmp_path):
    out = tmp_path / "fleet.yaml"
    r = _run("--json", "render", "--out", str(out))
    assert r.exit_code == 0, r.output
    doc = yaml.safe_load(out.read_text())
    assert "fleet-netbox" in doc["http"]["routers"]


def test_dns_rewrites_maps_hosts_to_pki_ip(patched):
    r = _run("--json", "dns-rewrites")
    assert r.exit_code == 0, r.output
    assert json.loads(r.output) == {"netbox.lab.test": "10.0.0.1"}


def test_dns_rewrites_empty_when_pki_not_up(monkeypatch):
    monkeypatch.setattr(tc, "discover_routes", lambda *_a, **_k: [dict(NETBOX_ROUTE)])

    def _raise(*_a, **_k):
        raise tc.typer.Exit(1)

    monkeypatch.setattr(tc, "resolve_domain", _raise)
    r = _run("--json", "dns-rewrites")
    assert r.exit_code == 0, r.output
    assert json.loads(r.output) == {}


def test_hosts_prints_etc_hosts_block(patched):
    r = _run("--json", "hosts")
    assert r.exit_code == 0, r.output
    data = json.loads(r.output)
    assert data["lines"] == ["10.0.0.1 netbox.lab.test"]


def test_check_passes_when_backend_reachable(patched, monkeypatch, http_server):
    ip, port = http_server
    original_probe = tc.probe_route
    monkeypatch.setattr(tc, "resolve_pki_ip", lambda *_a, **_k: ip)
    monkeypatch.setattr(tc, "probe_route", lambda **kw: original_probe(**{**kw, "port": port, "scheme": "http"}))
    r = _run("--json", "check")
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)["ok"] is True


def test_check_fails_when_backend_down(patched, monkeypatch):
    original_probe = tc.probe_route
    monkeypatch.setattr(tc, "resolve_pki_ip", lambda *_a, **_k: "127.0.0.1")
    monkeypatch.setattr(tc, "probe_route", lambda **kw: original_probe(**{**kw, "port": 1, "scheme": "http"}))
    r = _run("--json", "check")
    assert r.exit_code == pc_check_fail_exit()


def pc_check_fail_exit():
    import _pki_common as pc

    return pc.CHECK_FAIL_EXIT
