"""Metrics exporter layer: each enabled exporter listens and serves /metrics.

Parametrized over the `enabled_flags` output so a disabled exporter is skipped (not failed).
"""

import time

import pytest

# enable_* flag -> (port, a substring expected in that exporter's /metrics body)
FLAG_ENDPOINTS = [
    ("enable_node_exporter", 9100, "node_"),
    ("enable_adguard_exporter", 9618, "adguard_"),
    ("enable_unbound_exporter", 9167, "unbound_"),
    ("enable_process_exporter", 9256, "namedprocess_"),
    ("enable_systemd_exporter", 9558, "systemd_"),
]


def _wait_listening(host, port, timeout=240):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if host.socket(f"tcp://0.0.0.0:{port}").is_listening:
            return
        time.sleep(5)
    pytest.fail(f"nothing listening on :{port} after {timeout}s")


@pytest.mark.parametrize("flag,port,needle", FLAG_ENDPOINTS)
def test_enabled_exporter_serves_metrics(server, enabled_flags, flag, port, needle):
    if flag not in enabled_flags:
        pytest.skip(f"{flag} disabled")
    _wait_listening(server, port)
    res = server.run(f"curl -fsS http://localhost:{port}/metrics")
    assert res.rc == 0, f"{port}/metrics did not return 200"
    assert needle in res.stdout, f"{port}/metrics missing expected {needle!r} series"
