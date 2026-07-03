"""Controller VM (syslog-ng collector) — the exact syslog-ng 3.28.1 runs and receives logs."""


def test_syslogng_container_running(controller, version_mode):
    """In exact mode the appliance's syslog-ng runs in a container; in modern mode on the host."""
    if version_mode == "exact":
        out = controller.run("sudo docker ps --format '{{.Names}} {{.Status}}'")
        assert "unifi-syslog-ng" in out.stdout, out.stdout
        assert "Up" in out.stdout
    else:
        assert controller.service("syslog-ng").is_running


def test_syslogng_is_exact_version(controller, version_mode, versions):
    """The headline fidelity proof: the RUNNING syslog-ng is the appliance's 3.28.1."""
    want = versions["syslog_ng"].split("-")[0]  # 3.28.1-2+deb11u2 -> 3.28.1
    if version_mode == "exact":
        out = controller.run("sudo docker exec unifi-syslog-ng syslog-ng --version")
        assert want in out.stdout, f"expected {want} in:\n{out.stdout}"
    else:
        # modern mode runs Ubuntu-stock syslog-ng 4.x — assert it's present, not the exact version.
        out = controller.run("syslog-ng --version")
        assert out.rc == 0


def test_collector_port_listening(controller):
    """The syslog-ng network() collector must be listening on UDP :514 (the USG forwards here)."""
    out = controller.run("sudo ss -lun")
    assert ":514" in out.stdout, out.stdout


def test_remote_log_dir_exists(controller):
    """Received logs are partitioned under /var/log/remote/<host>/<program>.log."""
    assert controller.file("/var/log/remote").is_directory
