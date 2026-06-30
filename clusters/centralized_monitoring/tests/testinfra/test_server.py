"""Server VM: docker up, the spine listening, and every enabled compose service's port open.

Jobs are flag-gated, so port checks for optional services are parametrized over
`enabled_exporters` and skipped (not failed) when the feature is off.
"""

import time

import pytest

# enable_* flag -> (compose service name, host port) it exposes on the server.
SERVER_FLAG_PORTS = {
    "enable_openobserve": ("openobserve", 5080),
    "enable_otel": ("otel-collector", 4317),
    "enable_blackbox": ("blackbox_exporter", 9115),
    "enable_uptime_kuma": ("uptime-kuma", 3001),
    "enable_traefik": ("traefik", 8082),
    "enable_statsd_exporter": ("statsd_exporter", 9102),
    "enable_ssh_exporter": ("ssh_exporter", 9312),
    "enable_node_exporter": ("node_exporter", 9100),
    "enable_cadvisor": ("cadvisor", 8080),
    "enable_vector": ("vector", 8686),
}


def test_docker_running(server):
    assert server.service("docker").is_running


@pytest.mark.parametrize("port", [9090, 9093, 3000])
def test_spine_ports_listening(server, port):
    """Prometheus / Alertmanager / Grafana are always on."""
    _wait_listening(server, port)


@pytest.mark.parametrize("flag", list(SERVER_FLAG_PORTS))
def test_enabled_server_service_port(server, enabled_exporters, flag):
    if flag not in enabled_exporters:
        pytest.skip(f"{flag} disabled")
    _service, port = SERVER_FLAG_PORTS[flag]
    _wait_listening(server, port)


def _wait_listening(host, port, timeout=180):
    """Containers may still be pulling right after cloud-init; poll the socket."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if host.socket(f"tcp://0.0.0.0:{port}").is_listening:
            return
        time.sleep(5)
    pytest.fail(f"nothing listening on :{port} after {timeout}s")
