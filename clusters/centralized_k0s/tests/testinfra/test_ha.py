"""HA-mode live checks (`just verify centralized_k0s` when k0s_control_plane_count > 1).

The whole module skips in single-controller mode (enabled_features.ha == false). HA here is
etcd-quorum HA behind a SPOF HAProxy edge: the failover drill validates that killing ONE controller
leaves the API reachable (etcd 2/3 quorum + HAProxy backend health-checking), NOT that the HAProxy
itself is redundant (it isn't — that's the Proxmox target).
"""

import json
import time

import pytest


@pytest.fixture(scope="session")
def require_ha(enabled_features):
    if not enabled_features.get("ha"):
        pytest.skip("single-controller topology (enabled_features.ha == false)")
    return True


def test_etcd_member_list_has_three(require_ha, controller_1):
    """etcd is a 3-member quorum in HA mode."""
    res = controller_1.run("sudo k0s etcd member-list")
    assert res.rc == 0, f"`k0s etcd member-list` failed: {res.stderr}"
    members = json.loads(res.stdout).get("members", {})
    assert len(members) == 3, f"expected 3 etcd members, got {len(members)}: {res.stdout}"


def test_control_plane_survives_one_controller_down(require_ha, controller_1, controller_2):
    """Failover drill: stop k0scontroller on controller-2; the API stays reachable via the surviving
    quorum, then restore the member so the cluster returns to full health."""
    controller_2.run("sudo systemctl stop k0scontroller")
    try:
        deadline = time.time() + 120
        ok = False
        while time.time() < deadline:
            # controller-1 can still serve the API with 2/3 etcd quorum.
            if controller_1.run("sudo k0s kubectl get nodes").rc == 0:
                ok = True
                break
            time.sleep(5)
        assert ok, "API unreachable after a single controller was stopped (quorum lost?)"
    finally:
        controller_2.run("sudo systemctl start k0scontroller")

    # Give the restarted member time to rejoin, then confirm the quorum is whole again.
    deadline = time.time() + 180
    while time.time() < deadline:
        res = controller_1.run("sudo k0s etcd member-list")
        if res.rc == 0 and len(json.loads(res.stdout).get("members", {})) == 3:
            return
        time.sleep(10)
    pytest.fail("etcd did not return to 3 members after restarting the stopped controller")


def test_haproxy_native_prometheus_exporter(require_ha, haproxy):
    """The HAProxy edge serves its native Prometheus exporter on :8405/metrics."""
    deadline = time.time() + 120
    while time.time() < deadline:
        if haproxy.socket("tcp://0.0.0.0:8405").is_listening:
            break
        time.sleep(5)
    res = haproxy.run("curl -fsS http://localhost:8405/metrics")
    assert res.rc == 0, "HAProxy :8405/metrics did not return 200"
    assert "haproxy_" in res.stdout, "no haproxy_* series from the native exporter"
