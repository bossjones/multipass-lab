"""Services VM: Traefik + Authelia + Vaultwarden are up and reachable through Traefik."""

import time

import pytest

STACK = {"traefik", "authelia", "vaultwarden"}


def _wait(fn, timeout=180, interval=5):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        last = fn()
        if last:
            return last
        time.sleep(interval)
    return last


def test_docker_running(services):
    assert services.service("docker").is_running


def test_stack_containers_running(services):
    def _up():
        res = services.run(
            "sudo docker compose -f /opt/stack/compose.yaml ps "
            "--status running --format '{{.Service}}'"
        )
        return res.rc == 0 and not (STACK - set(res.stdout.split()))

    assert _wait(_up), "not all of traefik/authelia/vaultwarden are running"


@pytest.mark.parametrize("port", [80, 443, 8080])
def test_traefik_ports_listening(services, port):
    assert _wait(lambda: services.socket(f"tcp://0.0.0.0:{port}").is_listening)


def test_step_ca_root_trusted_on_host(services):
    assert services.file("/usr/local/share/ca-certificates/step-ca-root.crt").exists


def test_services_cert_issued(services, enabled_flags):
    if "enable_letsencrypt_staging" in enabled_flags:
        pytest.skip("LE staging mode: Traefik obtains certs via ACME, not the static file")
    assert _wait(lambda: services.file("/opt/stack/traefik/certs/services.crt").exists)


def test_authelia_reachable_through_traefik(services, domain):
    got = _wait(
        lambda: services.run(
            f"curl -fsSk -H 'Host: auth.{domain}' https://localhost/api/health"
        ).rc
        == 0
    )
    assert got, "Authelia not reachable through Traefik"


def test_vaultwarden_reachable_through_traefik(services, domain):
    got = _wait(
        lambda: services.run(
            f"curl -fsSk -H 'Host: warden.{domain}' https://localhost/alive"
        ).rc
        == 0
    )
    assert got, "Vaultwarden not reachable through Traefik"


def test_node_exporter_serves_metrics(services, enabled_flags):
    if "enable_node_exporter" not in enabled_flags:
        pytest.skip("enable_node_exporter disabled")
    assert _wait(lambda: services.socket("tcp://0.0.0.0:9100").is_listening)
    assert services.run("curl -fsS http://localhost:9100/metrics").rc == 0
