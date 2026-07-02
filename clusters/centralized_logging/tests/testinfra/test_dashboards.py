"""The docker VM now self-monitors the whole cluster: its local Prometheus scrapes all
three VMs' exporters and Grafana ships the provisioned dashboard set.

Proves the Phase-3 wiring end-to-end: every rendered scrape target is healthy (the
__SELF_IP__ substitution + cross-VM 0.0.0.0 binds all resolved), and Grafana loaded the
dashboards dropped via cloud-init, bound to the fixed `prometheus` datasource uid.
"""

import json
import time

import pytest


def _curl_json(host, url, timeout=180):
    """Poll an HTTP endpoint on the host until it returns parseable JSON."""
    deadline = time.time() + timeout
    last = ""
    while time.time() < deadline:
        res = host.run(f"curl -fsS {url}")
        if res.rc == 0 and res.stdout.strip():
            try:
                return json.loads(res.stdout)
            except json.JSONDecodeError:
                last = res.stdout
        time.sleep(5)
    pytest.fail(f"no JSON from {url} after {timeout}s (last: {last[:200]})")


def test_docker_prometheus_targets_up(docker):
    """Every scrape target the docker VM's Prometheus knows about must report up."""
    deadline = time.time() + 300
    down = None
    while time.time() < deadline:
        data = _curl_json(docker, "http://localhost:9090/api/v1/targets")
        active = data.get("data", {}).get("activeTargets", [])
        if active:
            down = [t["scrapeUrl"] for t in active if t.get("health") != "up"]
            if not down:
                return
        time.sleep(10)
    pytest.fail(f"logging-cluster targets not up: {down}")


def test_all_three_vms_scraped(docker, hosts):
    """logging-node must return up==1 for central, docker (self), and k0s."""
    data = _curl_json(
        docker,
        "http://localhost:9090/api/v1/query?query=up%7Bjob%3D%22logging-node%22%7D",
    )
    results = data.get("data", {}).get("result", [])
    up_instances = {
        r["metric"].get("instance", "") for r in results if r["value"][1] == "1"
    }
    for role in ("central", "docker", "k0s"):
        ip = hosts[role]["ipv4"]
        assert any(i.startswith(f"{ip}:") for i in up_instances), (
            f"{role} ({ip}) not up in logging-node job: {up_instances}"
        )


def test_grafana_dashboards_provisioned(docker):
    """Grafana on the docker VM loaded the provisioned dashboards + datasource uid."""
    ds = _curl_json(docker, "http://admin:admin@localhost:3000/api/datasources")
    uids = {d.get("uid") for d in ds if d.get("name") == "Prometheus"}
    assert "prometheus" in uids, (
        f"Prometheus datasource uid should be 'prometheus': {uids}"
    )

    search = _curl_json(
        docker, "http://admin:admin@localhost:3000/api/search?type=dash-db"
    )
    have = {d.get("uid") for d in search}
    expected = {
        "instance-overview",
        "processes-systemd",
        "node-exporter-full",
        "logging-pipeline",
    }
    missing = expected - have
    assert not missing, f"dashboards not provisioned: {missing} (have {have})"
