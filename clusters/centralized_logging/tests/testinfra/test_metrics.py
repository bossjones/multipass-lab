"""Metrics exporter layer: each enabled exporter listens and serves /metrics.

Endpoints are parametrized over the `enabled_exporters` fixture so a disabled exporter
is skipped (not failed). Nothing scrapes locally yet (a future centralized_monitoring
Prometheus pulls these), so the liveness check is a direct curl per endpoint plus a
cross-VM reachability probe confirming the 0.0.0.0 bind.
"""

import time

import pytest

# enable_* flag -> (role fixture name, port) it listens on. Roles map to conftest fixtures.
# Exporters present on multiple VMs get one entry per VM.
FLAG_ENDPOINTS = [
    ("enable_node_exporter", "central", 9100),
    ("enable_node_exporter", "k0s", 9100),
    ("enable_node_exporter", "docker", 9100),
    ("enable_systemd_exporter", "central", 9558),
    ("enable_systemd_exporter", "k0s", 9558),
    ("enable_systemd_exporter", "docker", 9558),
    ("enable_process_exporter", "central", 9256),
    ("enable_process_exporter", "k0s", 9256),
    ("enable_process_exporter", "docker", 9256),
    ("enable_filestat_exporter", "central", 9943),
    ("enable_cadvisor", "k0s", 8089),
    ("enable_cadvisor", "docker", 8089),
    ("enable_journald_exporter", "central", 12345),
    ("enable_journald_exporter", "k0s", 12345),
    ("enable_journald_exporter", "docker", 12345),
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


def test_syslogng_textfile_present(central, enabled_exporters):
    if "enable_syslogng_metrics" not in enabled_exporters:
        pytest.skip("enable_syslogng_metrics disabled")
    prom = "/var/lib/node_exporter/textfile_collector/syslogng.prom"
    deadline = time.time() + 120
    while time.time() < deadline:
        if central.file(prom).exists:
            break
        time.sleep(5)
    assert central.file(prom).exists, f"{prom} was never written"
    assert "syslogng_" in central.file(prom).content_string


def test_systemd_exporter_reports_syslog_ng_unit(central, enabled_exporters):
    if "enable_systemd_exporter" not in enabled_exporters:
        pytest.skip("enable_systemd_exporter disabled")
    _wait_listening(central, 9558)
    res = central.run("curl -fsS http://localhost:9558/metrics")
    assert res.rc == 0
    assert "syslog-ng.service" in res.stdout


def test_cross_vm_reachability(k0s, central, hosts, enabled_exporters):
    """A peer VM can reach central's node_exporter — the 0.0.0.0-bind precondition for
    the future cross-cluster scrape."""
    if "enable_node_exporter" not in enabled_exporters:
        pytest.skip("enable_node_exporter disabled")
    central_ip = hosts["central"]["ipv4"]
    _wait_listening(central, 9100)
    res = k0s.run(f"curl -fsS http://{central_ip}:9100/metrics")
    assert res.rc == 0, f"k0s could not reach central {central_ip}:9100 (not bound 0.0.0.0?)"
