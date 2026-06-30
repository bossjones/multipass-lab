"""End-to-end (headline): the server is really PULLING the monitored host.

Proves the full pull path: Prometheus on the server scrapes every flag-gated target,
the k0s client's metrics arrive, blackbox probes succeed, and Grafana came up with its
datasources provisioned — no click-ops. Because jobs are flag-gated, the target set
equals `enabled_exporters`; we assert every target Prometheus knows about is healthy.
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


def test_all_prometheus_targets_up(server):
    """Every scrape target Prometheus has must report health == 'up'."""
    # Give scrapes time to land after first boot.
    deadline = time.time() + 300
    down = None
    while time.time() < deadline:
        data = _curl_json(server, "http://localhost:9090/api/v1/targets")
        active = data.get("data", {}).get("activeTargets", [])
        if active:
            down = [
                t["scrapeUrl"]
                for t in active
                if t.get("health") != "up"
            ]
            if not down:
                return
        time.sleep(10)
    pytest.fail(f"targets not up: {down}")


def test_client_instance_up_and_has_metrics(server, hosts, enabled_exporters):
    """up{instance=~"<k0s_ip>.*"} == 1 and a real metric returns for the client."""
    if "enable_node_exporter" not in enabled_exporters:
        pytest.skip("enable_node_exporter disabled")
    k0s_ip = hosts["k0s"]["ipv4"]

    up = _curl_json(
        server,
        f"http://localhost:9090/api/v1/query?query=up%7Binstance%3D~%22{k0s_ip}.%2A%22%7D",
    )
    results = up.get("data", {}).get("result", [])
    assert any(r["value"][1] == "1" for r in results), f"no up==1 for {k0s_ip}"

    load = _curl_json(
        server, "http://localhost:9090/api/v1/query?query=node_load1"
    )
    assert load.get("data", {}).get("result"), "node_load1 returned no data"


def test_blackbox_probe_succeeds(server, enabled_exporters):
    if "enable_blackbox" not in enabled_exporters:
        pytest.skip("enable_blackbox disabled")
    # blackbox returns Prometheus text (not JSON), so assert on the raw body. The probe
    # target uses the compose service name — blackbox resolves it on the docker network.
    res = server.run(
        "curl -fsS 'http://localhost:9115/probe?module=http_2xx"
        "&target=http://grafana:3000/login'"
    )
    assert res.rc == 0
    assert "probe_success 1" in res.stdout


def test_grafana_datasources_provisioned(server, enabled_exporters):
    """Grafana API lists Prometheus (always) and OpenObserve (when enabled)."""
    data = _curl_json(
        server, "http://admin:admin@localhost:3000/api/datasources"
    )
    names = {ds.get("name") for ds in data}
    assert "Prometheus" in names, f"Prometheus datasource missing: {names}"
    if "enable_openobserve" in enabled_exporters:
        assert "OpenObserve" in names, f"OpenObserve datasource missing: {names}"
