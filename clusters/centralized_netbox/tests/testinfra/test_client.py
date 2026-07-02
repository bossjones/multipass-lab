"""Live checks for the client VM: the self-registration oneshot ran successfully."""


def test_register_service_succeeded(client):
    """netbox-register.service is a oneshot with RemainAfterExit — success leaves it active."""
    assert client.run("systemctl is-active netbox-register.service").stdout.strip() == "active"


def test_register_exit_status_zero(client):
    res = client.run("systemctl show -p ExecMainStatus --value netbox-register.service")
    assert res.stdout.strip() == "0"


def test_register_marker_present(client):
    assert client.file("/var/lib/netbox-register/done").exists
