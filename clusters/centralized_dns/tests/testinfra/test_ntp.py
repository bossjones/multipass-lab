"""Time sync: the DNS VM is pinned to UTC and running an enabled, synchronized NTP client.

The cloud-init `timezone: Etc/UTC` + `ntp: {ntp_client: systemd-timesyncd}` baseline is
unconditional (no enable_* flag), so these checks run against the server fixture with no skip
guard. `conftest._connect` already blocks on `cloud-init status --wait`, so the config is applied
before we assert; `_wait_synchronized` only tolerates first-boot sync lag.

The service check is deliberately tolerant: in the default build the box runs systemd-timesyncd
as a client, but when it is brought up as the fleet NTP hub (enable_ntp_server / INTERNAL_NTP) it
runs chrony instead — installing chrony disables timesyncd. Either satisfies "an NTP client is
active" and both report NTP=yes / NTPSynchronized=yes via timedatectl. See specs/shared-ntp.md.
"""

import time

import pytest

# A freshly-booted VM can take a moment to reach its first successful sync.
SYNC_TIMEOUT = 120

ROLES = ["server"]


def _timezone(host):
    return host.run("timedatectl show -p Timezone --value").stdout.strip()


def _ntp_enabled(host):
    return host.run("timedatectl show -p NTP --value").stdout.strip()


def _ntp_service_active(host):
    # Client mode -> systemd-timesyncd; hub mode -> chrony (chrony's install disables timesyncd).
    for svc in ("systemd-timesyncd", "chrony", "chronyd"):
        if host.run(f"systemctl is-active {svc}").stdout.strip() == "active":
            return True
    return False


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
    assert _ntp_service_active(host), f"{role} has no active NTP client (timesyncd/chrony)"


@pytest.mark.parametrize("role", ROLES)
def test_clock_synchronized(request, role):
    host = request.getfixturevalue(role)
    assert _wait_synchronized(host), f"{role} clock never reached NTPSynchronized=yes"
