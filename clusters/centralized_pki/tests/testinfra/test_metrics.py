"""Metrics exporter layer: each enabled exporter listens and serves /metrics.

Parametrized over the `enabled_flags` output so a disabled exporter is skipped (not failed).
Nothing scrapes locally yet (a future centralized_monitoring Prometheus pulls these
cross-cluster), so the liveness check is a direct curl per endpoint.
"""

import time

import pytest

# enable_* flag -> (role fixture name, port). Both exporters run on both PKI VMs.
FLAG_ENDPOINTS = [
    ("enable_node_exporter", "ca", 9100),
    ("enable_node_exporter", "services", 9100),
    ("enable_process_exporter", "ca", 9256),
    ("enable_process_exporter", "services", 9256),
    ("enable_systemd_exporter", "ca", 9558),
    ("enable_systemd_exporter", "services", 9558),
]


def _wait_listening(host, port, timeout=180):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if host.socket(f"tcp://0.0.0.0:{port}").is_listening:
            return
        time.sleep(5)
    pytest.fail(f"nothing listening on :{port} after {timeout}s")


@pytest.mark.parametrize("flag,role,port", FLAG_ENDPOINTS)
def test_enabled_exporter_serves_metrics(request, enabled_flags, flag, role, port):
    if flag not in enabled_flags:
        pytest.skip(f"{flag} disabled")
    host = request.getfixturevalue(role)
    _wait_listening(host, port)
    res = host.run(f"curl -fsS http://localhost:{port}/metrics")
    assert res.rc == 0, f"{role}:{port}/metrics did not return 200"
