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


# unbound's postinst pulls in resolvconf and triggers unbound-resolvconf.service, which fails on
# every boot ("Link lo is loopback device") since this box is systemd-resolved-driven, never
# resolvconf-driven — masked via bootcmd. cloud-final.service is the module that runs `runcmd`;
# regressions in any runcmd step surface there.
FAILURE_PRONE_UNITS = ["unbound-resolvconf.service", "cloud-final.service"]


@pytest.mark.parametrize("unit", FAILURE_PRONE_UNITS)
def test_unit_not_failed(server, unit):
    result = server.run(f"systemctl is-failed {unit}")
    assert result.stdout.strip() != "failed", f"{unit} is in a failed state"
