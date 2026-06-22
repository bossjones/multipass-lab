"""End-to-end: a log emitted on a client reaches the central collector.

This is the headline test for the cluster — it proves the full syslog-ng client ->
TCP/disk-buffer -> central -> /var/log/remote path actually works.
"""

import time
import uuid

import pytest


@pytest.mark.parametrize("role", ["k0s", "docker"])
def test_log_reaches_central(request, role, central):
    host = request.getfixturevalue(role)
    token = f"e2e-{uuid.uuid4().hex}"

    assert host.run(f"logger -t e2e {token}").rc == 0

    deadline = time.time() + 60
    while time.time() < deadline:
        res = central.run(f"sudo grep -rl {token} /var/log/remote/ || true")
        if token in central.run(f"sudo grep -rh {token} /var/log/remote/ || true").stdout:
            return
        if res.stdout.strip():
            return
        time.sleep(3)

    pytest.fail(f"log token {token} from {role} never reached central /var/log/remote")


@pytest.mark.parametrize("role", ["k0s", "docker"])
def test_keep_mode_folders_by_hostname(request, role, central, hosts, hostname_source):
    """In `keep` mode, a client's logs land under /var/log/remote/<client-hostname>/."""
    if hostname_source != "keep":
        pytest.skip(f"hostname_source={hostname_source}; hostname foldering only asserted for 'keep'")

    host = request.getfixturevalue(role)
    name = hosts[role]["name"]
    token = f"host-{uuid.uuid4().hex}"

    assert host.run(f"logger -t hosttest {token}").rc == 0

    target = f"/var/log/remote/{name}/"
    deadline = time.time() + 60
    while time.time() < deadline:
        if central.run(f"sudo grep -rl {token} {target} || true").stdout.strip():
            return
        time.sleep(3)

    pytest.fail(f"{role} log not foldered under hostname dir {target}")
