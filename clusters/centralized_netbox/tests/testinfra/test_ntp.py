"""Every VM pins UTC and keeps the clock disciplined via systemd-timesyncd (see specs/ntp.md)."""

import time

import pytest

ROLES = ["server", "client"]


def _timezone(host):
    return host.run("timedatectl show -p Timezone --value").stdout.strip()


def _ntp_client(host):
    # cloud-init writes /etc/systemd/timesyncd.conf; the service being active is the real signal.
    return host.run("systemctl is-active systemd-timesyncd").stdout.strip()


@pytest.mark.parametrize("role", ROLES)
def test_timezone_is_utc(request, role):
    host = request.getfixturevalue(role)
    assert _timezone(host) == "Etc/UTC"


@pytest.mark.parametrize("role", ROLES)
def test_timesyncd_active(request, role):
    host = request.getfixturevalue(role)
    assert _ntp_client(host) == "active"


@pytest.mark.parametrize("role", ROLES)
def test_clock_synchronized(request, role):
    host = request.getfixturevalue(role)
    deadline = time.time() + 120
    while time.time() < deadline:
        synced = host.run("timedatectl show -p NTPSynchronized --value").stdout.strip()
        if synced == "yes":
            return
        time.sleep(5)
    raise AssertionError(f"{role} clock never reported NTPSynchronized=yes")
