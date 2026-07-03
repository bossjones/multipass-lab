"""Metrics exporter layer: each enabled exporter listens and serves /metrics.

Parametrized over the `enabled_exporters` output so a disabled exporter is skipped (not
failed). This cluster shipped no exporters before; both VMs now install node_exporter,
process-exporter, and systemd_exporter via the same install-exporter.sh pattern as the other
clusters. Nothing scrapes locally (a future centralized_monitoring Prometheus pulls these
cross-cluster), so the liveness check is a direct curl per endpoint.
"""

import time

import pytest

# enable_* flag -> (role fixture name, port). All three exporters run on both VMs.
FLAG_ENDPOINTS = [
    ("enable_node_exporter", "server", 9100),
    ("enable_node_exporter", "client", 9100),
    ("enable_process_exporter", "server", 9256),
    ("enable_process_exporter", "client", 9256),
    ("enable_systemd_exporter", "server", 9558),
    ("enable_systemd_exporter", "client", 9558),
]


def _wait_listening(host, port, timeout=180):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if host.socket(f"tcp://0.0.0.0:{port}").is_listening:
            return
        time.sleep(5)
    pytest.fail(f"nothing listening on :{port} after {timeout}s")


@pytest.mark.parametrize("flag,role,port", FLAG_ENDPOINTS)
def test_enabled_exporter_serves_metrics(request, enabled_exporters, flag, role, port):
    if flag not in enabled_exporters:
        pytest.skip(f"{flag} disabled")
    host = request.getfixturevalue(role)
    _wait_listening(host, port)
    res = host.run(f"curl -fsS http://localhost:{port}/metrics")
    assert res.rc == 0, f"{role}:{port}/metrics did not return 200"
