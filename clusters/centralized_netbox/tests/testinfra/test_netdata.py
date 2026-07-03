"""Live checks for the Netdata real-time agent (:19999) on both VMs.

Skip-not-fail when `enable_netdata` is off. The kickstart installer is slow on first
boot, so the port/HTTP checks poll with a deadline. This cluster has no Prometheus, so
Netdata is dashboard-only — there is no scrape-target assertion.
"""

import time

import pytest

# Both VMs run Netdata; role names match the `hosts` output / conftest fixtures.
NETDATA_ROLES = ["server", "client"]
BOOT_TIMEOUT = 300  # kickstart install + first listen can be slow on first boot


@pytest.fixture(scope="session")
def require_netdata(enabled_features):
    """Skip the whole module unless Netdata is enabled for this cluster."""
    if not enabled_features.get("netdata"):
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
