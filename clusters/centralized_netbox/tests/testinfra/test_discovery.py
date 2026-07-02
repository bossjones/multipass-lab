"""Live discovery suite (opt-in). Skipped entirely when enable_discovery is false.

Asserts the Diode plugin is installed in NetBox, the Diode server stack is running with its
/metrics reachable, the orb-agent VM is running discovery, and — the headline — that the agent's
network_discovery of the Multipass /24 populated NetBox IPAM with a host it did NOT hand-register
(the agent VM's own IP is never self-registered, so its presence is proof a scan ran end to end).
See specs/netbox-discovery.md.
"""

import time

import httpx
import pytest


@pytest.fixture(autouse=True)
def _require_discovery(discovery):
    if not discovery["enabled"]:
        pytest.skip("discovery disabled (enable_discovery=false)")


@pytest.fixture(scope="session")
def api(netbox):
    headers = {"Authorization": f"Token {netbox['token']}", "Accept": "application/json"}
    with httpx.Client(base_url=netbox["base_url"], headers=headers, timeout=15) as c:
        yield c


def test_diode_plugin_installed(api):
    """NetBox reports installed plugins in /api/status/; the Diode plugin must be among them."""
    resp = api.get("/api/status/")
    resp.raise_for_status()
    plugins = resp.json().get("plugins", {})
    assert "netbox_diode_plugin" in plugins, f"diode plugin not installed; plugins={plugins}"


def test_diode_stack_running(server):
    # The server fixture waits on /var/lib/netbox-bootstrap/done, which is touched only after the
    # Diode bring-up wrote discovery-done — so both markers exist here.
    assert server.run("test -f /var/lib/netbox-bootstrap/discovery-done").rc == 0
    ps = server.run("docker compose -f /opt/diode/docker-compose.yaml ps")
    assert ps.rc == 0, ps.stderr
    assert "diode-ingester" in ps.stdout
    assert "diode-reconciler" in ps.stdout


def test_diode_metrics_reachable(discovery):
    resp = httpx.get(discovery["diode_metrics_url"], timeout=15)
    assert resp.status_code == 200, f"Diode /metrics returned {resp.status_code}"


def test_agent_running(agent):
    assert agent.run("systemctl is-active orb-agent.service").stdout.strip() == "active"
    images = agent.run("docker ps --format '{{.Image}}'").stdout
    assert "orb-agent" in images, f"orb-agent container not running; images={images!r}"


def test_agent_ip_discovered(api, hosts):
    """Headline E2E: the /24 scan reconciled the agent VM's own IP into NetBox IPAM. Poll, since the
    scan + Diode reconcile are asynchronous."""
    agent_ip = hosts["agent"]["ipv4"]
    deadline = time.time() + 300
    last = 0
    while time.time() < deadline:
        resp = api.get("/api/ipam/ip-addresses/", params={"q": agent_ip})
        if resp.status_code == 200:
            addrs = {r["address"].split("/")[0] for r in resp.json()["results"]}
            last = resp.json()["count"]
            if agent_ip in addrs:
                return
        time.sleep(10)
    pytest.fail(f"agent IP {agent_ip} not discovered into NetBox IPAM after 300s (matches seen={last})")
