"""Time sync: every VM is pinned to UTC and running an enabled, synchronized NTP client.

The cloud-init `timezone: Etc/UTC` + `ntp: {ntp_client: systemd-timesyncd}` block is
unconditional (no enable_* flag), so these checks run against every role fixture with no
skip guard. `conftest._connect` already blocks on `cloud-init status --wait`, so the config
is applied before we assert; `_wait_synchronized` only tolerates first-boot sync lag.
"""

import time

import pytest

# A freshly-booted VM can take a moment to reach its first successful sync.
SYNC_TIMEOUT = 120

ROLES = ["ca", "services"]


def _timezone(host):
    return host.run("timedatectl show -p Timezone --value").stdout.strip()


def _ntp_enabled(host):
    return host.run("timedatectl show -p NTP --value").stdout.strip()


def _wait_synchronized(host):
    deadline = time.time() + SYNC_TIMEOUT
    while time.time() < deadline:
        if (
            host.run("timedatectl show -p NTPSynchronized --value").stdout.strip()
            == "yes"
        ):
            return True
        time.sleep(5)
    return False


@pytest.mark.parametrize("role", ROLES)
def test_timezone_is_utc(request, role):
    host = request.getfixturevalue(role)
    assert _timezone(host) == "Etc/UTC", f"{role} timezone is not Etc/UTC"


@pytest.mark.parametrize("role", ROLES)
def test_ntp_enabled_and_service_active(request, role):
    host = request.getfixturevalue(role)
    assert _ntp_enabled(host) == "yes", f"{role} does not report NTP=yes"
    assert (
        host.run("systemctl is-active systemd-timesyncd").stdout.strip() == "active"
    ), f"{role} systemd-timesyncd is not active"


@pytest.mark.parametrize("role", ROLES)
def test_clock_synchronized(request, role):
    host = request.getfixturevalue(role)
    assert _wait_synchronized(host), f"{role} clock never reached NTPSynchronized=yes"
