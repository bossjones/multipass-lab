"""Central logging VM: syslog-ng server is up, listening, and collecting."""


def test_syslog_ng_running_and_enabled(central):
    svc = central.service("syslog-ng")
    assert svc.is_running
    assert svc.is_enabled


def test_listening_on_syslog_port(central):
    assert central.socket("tcp://0.0.0.0:514").is_listening


def test_remote_log_dir_exists(central):
    assert central.file("/var/log/remote").is_directory
