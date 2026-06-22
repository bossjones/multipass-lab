"""Client VMs: syslog-ng shipper is up, plus their workloads (k0s / docker stack)."""

import time

import pytest

STACK_SERVICES = {"traefik", "heimdall", "prometheus", "alertmanager", "grafana"}


@pytest.mark.parametrize("role", ["k0s", "docker"])
def test_syslog_ng_running(request, role):
    host = request.getfixturevalue(role)
    assert host.service("syslog-ng").is_running


@pytest.mark.parametrize("role", ["k0s", "docker"])
def test_disk_buffer_dir_exists(request, role):
    host = request.getfixturevalue(role)
    assert host.file("/var/lib/syslog-ng").is_directory


def test_k0s_status_healthy(k0s):
    assert k0s.run("sudo k0s status").rc == 0


def test_docker_running(docker):
    assert docker.service("docker").is_running


def test_docker_log_driver_is_journald(docker):
    res = docker.run("sudo docker info --format '{{.LoggingDriver}}'")
    assert res.rc == 0
    assert res.stdout.strip() == "journald"


def test_docker_stack_all_services_running(docker):
    # Containers may still be pulling/starting right after cloud-init; poll briefly.
    deadline = time.time() + 120
    missing = STACK_SERVICES
    while time.time() < deadline:
        res = docker.run(
            "sudo docker compose -f /opt/stack/compose.yaml ps "
            "--status running --format '{{.Service}}'"
        )
        if res.rc == 0:
            missing = STACK_SERVICES - set(res.stdout.split())
            if not missing:
                return
        time.sleep(5)
    pytest.fail(f"stack services not running: {missing}")
