"""Live checks for the NetBox server VM: Docker + the netbox-docker stack + the bootstrap."""

import time

NETBOX_SERVICES = {"netbox", "netbox-worker", "postgres", "redis"}


def test_docker_running(server):
    assert server.service("docker").is_running


def test_netbox_stack_containers_running(server):
    """The core netbox-docker services must be up (poll — first boot pulls + migrates)."""
    deadline = time.time() + 180
    missing = NETBOX_SERVICES
    while time.time() < deadline:
        res = server.run(
            "sudo docker compose -f /opt/netbox-docker/docker-compose.yml ps "
            "--status running --format '{{.Service}}'"
        )
        if res.rc == 0:
            running = set(res.stdout.split())
            missing = {s for s in NETBOX_SERVICES if s not in running}
            if not missing:
                return
        time.sleep(5)
    raise AssertionError(f"netbox-docker services not running: {missing}")


def test_netbox_port_listening(server):
    assert server.socket("tcp://0.0.0.0:8000").is_listening


def test_api_status_ok(server, netbox):
    """NetBox answers its health endpoint on the published port (auth via the pinned token)."""
    tok = netbox["token"]
    deadline = time.time() + 180
    while time.time() < deadline:
        res = server.run(
            "curl -fsS -H %s http://localhost:8000/api/status/",
            f"Authorization: Token {tok}",
        )
        if res.rc == 0 and "netbox-version" in res.stdout:
            return
        time.sleep(5)
    raise AssertionError("GET /api/status/ never returned a healthy body")


def test_bootstrap_marker_present(server):
    """The bootstrap script created the virtualization cluster-type + cluster and marked done."""
    assert server.file("/var/lib/netbox-bootstrap/done").exists
