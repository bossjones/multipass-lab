"""CA VM: step-ca is up, healthy, and exposes an ACME + JWK provisioner."""

import time

import pytest


def _wait(fn, timeout=180, interval=5):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        last = fn()
        if last:
            return last
        time.sleep(interval)
    return last


def test_docker_running(ca):
    assert ca.service("docker").is_running


def test_step_ca_container_running(ca):
    got = _wait(
        lambda: ca.run("sudo docker inspect -f '{{.State.Running}}' step-ca").stdout.strip()
        == "true"
    )
    assert got, "step-ca container is not running"


def test_listening_on_9000(ca):
    assert _wait(lambda: ca.socket("tcp://0.0.0.0:9000").is_listening)


def test_health_ok(ca):
    got = _wait(
        lambda: '"status":"ok"'
        in ca.run("curl -fsSk https://localhost:9000/health").stdout.replace(" ", "")
    )
    assert got, "step-ca /health did not report ok"


def test_acme_and_jwk_provisioners_present(ca):
    out = _wait(
        lambda: ca.run("curl -fsSk https://localhost:9000/provisioners").stdout or None
    )
    assert out, "could not read /provisioners"
    assert '"type":"ACME"' in out.replace(" ", "") or '"type":"acme"' in out.lower().replace(" ", "")
    assert "admin" in out


def test_root_cert_exists_in_container(ca):
    assert ca.run(
        "sudo docker exec step-ca test -f /home/step/certs/root_ca.crt"
    ).rc == 0


def test_node_exporter_serves_metrics(ca, enabled_flags):
    if "enable_node_exporter" not in enabled_flags:
        pytest.skip("enable_node_exporter disabled")
    assert _wait(lambda: ca.socket("tcp://0.0.0.0:9100").is_listening)
    assert ca.run("curl -fsS http://localhost:9100/metrics").rc == 0
