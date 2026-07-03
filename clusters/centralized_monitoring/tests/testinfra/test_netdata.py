"""Live checks for the Netdata real-time agent (:19999) on every VM.

Skip-not-fail when `enable_netdata` is off. The kickstart installer is slow on first
boot, so the port/HTTP checks poll with a deadline rather than assuming instant.
On this Prometheus-bearing cluster we additionally assert the `netdata` scrape job
is `up` (server agent reached via host.docker.internal, k0s over its DHCP IP).
"""

import json
import time

import pytest

# Every VM runs Netdata; role names match the `hosts` output / conftest fixtures.
NETDATA_ROLES = ["server", "k0s"]
BOOT_TIMEOUT = 300  # kickstart install + first listen can be slow on first boot


@pytest.fixture(scope="session")
def require_netdata(enabled_exporters):
    """Skip the whole module unless Netdata is enabled for this cluster."""
    if "enable_netdata" not in enabled_exporters:
        pytest.skip("enable_netdata is off")
    return True


def _wait_listening(host, port, timeout=BOOT_TIMEOUT):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if host.socket(f"tcp://0.0.0.0:{port}").is_listening:
            return
        time.sleep(5)
    pytest.fail(f"nothing listening on :{port} after {timeout}s")


@pytest.mark.parametrize("role", NETDATA_ROLES)
def test_netdata_running_and_serves_prometheus(request, require_netdata, role):
    """Per VM: the netdata service runs, :19999 listens, and the Prometheus export works."""
    host = request.getfixturevalue(role)
    assert host.service("netdata").is_running, f"netdata not running on {role}"
    _wait_listening(host, 19999)
    res = host.run(
        "curl -fsS 'http://localhost:19999/api/v1/allmetrics?format=prometheus'"
    )
    assert res.rc == 0, f"netdata prometheus endpoint failed on {role}"
    assert "netdata_" in res.stdout, f"no netdata_* metrics from {role}"


def test_netdata_target_up_in_prometheus(server, require_netdata):
    """The `netdata` scrape job must report up==1 for its targets."""
    deadline = time.time() + BOOT_TIMEOUT
    last = []
    while time.time() < deadline:
        res = server.run(
            "curl -fsS 'http://localhost:9090/api/v1/query?query=up%7Bjob%3D%22netdata%22%7D'"
        )
        if res.rc == 0 and res.stdout.strip():
            data = json.loads(res.stdout)
            last = data.get("data", {}).get("result", [])
            if last and any(r["value"][1] == "1" for r in last):
                return
        time.sleep(10)
    pytest.fail(f"no up==1 netdata target after {BOOT_TIMEOUT}s (last: {last})")
