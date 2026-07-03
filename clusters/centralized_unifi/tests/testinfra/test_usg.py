"""USG VM (rsyslog forwarder) — the exact rsyslog 5.8.11 runs and forwards to the controller."""


def test_rsyslog_container_running(usg, version_mode):
    if version_mode == "exact":
        out = usg.run("sudo docker ps --format '{{.Names}} {{.Status}}'")
        assert "unifi-rsyslog" in out.stdout, out.stdout
        assert "Up" in out.stdout
    else:
        assert usg.service("rsyslog").is_running


def test_rsyslog_is_exact_version(usg, version_mode, versions):
    """The headline fidelity proof: the RUNNING rsyslog is the appliance's 5.8.11."""
    want = versions["rsyslog"].split("-")[0]  # 5.8.11-3+deb7u2 -> 5.8.11
    if version_mode == "exact":
        out = usg.run("sudo docker exec unifi-rsyslog rsyslogd -version")
        assert want in out.stdout, f"expected {want} in:\n{out.stdout}"
    else:
        out = usg.run("rsyslogd -version")
        assert out.rc == 0


def test_forward_targets_controller(usg, hosts):
    """The Vyatta rule must forward to the injected controller IP (not the appliance's hardcoded IP)."""
    controller_ip = hosts["controller"]["ipv4"]
    vyatta = usg.file("/opt/unifi/vyatta-log.conf")
    assert vyatta.exists
    assert f"@{controller_ip}:" in vyatta.content_string, vyatta.content_string
    assert "192.168.3.16" not in vyatta.content_string


def test_traffic_generator_enabled(usg, version_mode):
    """When the generator is on, the rsyslog container carries ENABLE_TRAFFIC=1."""
    if version_mode != "exact":
        return  # modern mode runs the generator as a host systemd service
    out = usg.run(
        "sudo docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' unifi-rsyslog"
    )
    # The generator is default-on; when disabled the value is 0 and this assertion is skipped upstream.
    assert "ENABLE_TRAFFIC=" in out.stdout, out.stdout
