"""Service layer: AdGuard Home + Unbound + exporters run host-level under systemd."""

import pytest

# systemd unit -> the enable_* flag gating it (None = always on).
UNITS = [
    ("unbound", None),
    ("AdGuardHome", None),
    ("node_exporter", "enable_node_exporter"),
    ("adguard-exporter", "enable_adguard_exporter"),
    ("unbound_exporter", "enable_unbound_exporter"),
    ("process-exporter", "enable_process_exporter"),
    ("systemd_exporter", "enable_systemd_exporter"),
]


@pytest.mark.parametrize("unit,flag", UNITS)
def test_unit_running(server, enabled_flags, unit, flag):
    if flag is not None and flag not in enabled_flags:
        pytest.skip(f"{flag} disabled")
    svc = server.service(unit)
    assert svc.is_running, f"{unit} is not running"


def test_no_docker_on_dns_path(server):
    """The DNS stack must be host-level systemd, not Docker."""
    assert not server.package("docker-ce").is_installed
