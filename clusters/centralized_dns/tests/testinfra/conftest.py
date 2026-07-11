"""Build testinfra SSH hosts from `tofu output -json`.

The cluster injects the local SSH public key into the ubuntu user via cloud-init, so we connect
over SSH using the matching private key. IPs come from the `hosts` output. StrictHostKeyChecking
is disabled — these are throwaway lab VMs whose host keys change every `just up`.
"""

import json
import os
import subprocess
import time
from pathlib import Path

import pytest
import testinfra

# The DNS VM builds two exporters from source (go install) + runs the AdGuard installer, so give
# cloud-init a generous ceiling.
CONNECT_TIMEOUT = 120
CLOUD_INIT_TIMEOUT = 900

# tests/testinfra/ -> clusters/centralized_dns/
CLUSTER_DIR = Path(__file__).resolve().parents[2]
SSH_KEY = os.path.expanduser(os.environ.get("CLUSTER_SSH_KEY", "~/.ssh/id_ed25519"))


@pytest.fixture(scope="session")
def tofu_output():
    """Return the full parsed `tofu output -json`."""
    raw = subprocess.run(
        ["tofu", f"-chdir={CLUSTER_DIR}", "output", "-json"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return json.loads(raw)


@pytest.fixture(scope="session")
def hosts(tofu_output):
    """Return the cluster `hosts` output: {role: {name, ipv4}}."""
    return tofu_output["hosts"]["value"]


@pytest.fixture(scope="session")
def enabled_flags(tofu_output):
    """Sorted list of active exporter flags. Tests parametrize over this so a disabled exporter
    is skipped (not failed)."""
    return tofu_output["enabled_flags"]["value"]


@pytest.fixture(scope="session")
def ha_mode(hosts):
    """True when the cluster is deployed in HA mode (primary/secondary roles instead of server)."""
    return "primary" in hosts and "secondary" in hosts


@pytest.fixture(scope="session")
def vip(tofu_output):
    """The keepalived floating VIP (`vip_address` output); empty string in single mode."""
    return tofu_output.get("vip_address", {}).get("value", "")


def _primary_or_server(hosts):
    # In HA mode there is no `server` role; the primary node is the equivalent full DNS node, so the
    # single-mode test suite (test_dns/test_services/test_metrics/test_ntp) runs against it.
    return "server" if "server" in hosts else "primary"


@pytest.fixture(scope="session")
def server_ip(hosts):
    return hosts[_primary_or_server(hosts)]["ipv4"]


@pytest.fixture(scope="session")
def primary_ip(hosts, ha_mode):
    if not ha_mode:
        pytest.skip("not HA mode (no primary node)")
    return hosts["primary"]["ipv4"]


@pytest.fixture(scope="session")
def secondary_ip(hosts, ha_mode):
    if not ha_mode:
        pytest.skip("not HA mode (no secondary node)")
    return hosts["secondary"]["ipv4"]


@pytest.fixture(scope="session")
def ssh_config_file(tmp_path_factory):
    cfg = tmp_path_factory.mktemp("ssh") / "config"
    cfg.write_text(
        "Host *\n"
        "  StrictHostKeyChecking no\n"
        "  UserKnownHostsFile /dev/null\n"
        "  LogLevel ERROR\n"
        f"  IdentityFile {SSH_KEY}\n"
        "  User ubuntu\n"
    )
    return str(cfg)


def _connect(ip, ssh_config_file):
    """Connect over SSH, then wait until the VM is reachable and cloud-init is done."""
    host = testinfra.get_host(f"ssh://ubuntu@{ip}", ssh_config=ssh_config_file)

    deadline = time.time() + CONNECT_TIMEOUT
    while True:
        try:
            if host.run("true").rc == 0:
                break
        except Exception:  # noqa: BLE001 - retry until reachable or timeout
            pass
        if time.time() >= deadline:
            raise TimeoutError(f"VM {ip} not SSH-reachable after {CONNECT_TIMEOUT}s")
        time.sleep(3)

    host.run(f"timeout {CLOUD_INIT_TIMEOUT} cloud-init status --wait")
    return host


@pytest.fixture(scope="session")
def server(hosts, ssh_config_file):
    return _connect(hosts[_primary_or_server(hosts)]["ipv4"], ssh_config_file)


@pytest.fixture(scope="session")
def primary(hosts, ssh_config_file, ha_mode):
    if not ha_mode:
        pytest.skip("not HA mode (no primary node)")
    return _connect(hosts["primary"]["ipv4"], ssh_config_file)


@pytest.fixture(scope="session")
def secondary(hosts, ssh_config_file, ha_mode):
    if not ha_mode:
        pytest.skip("not HA mode (no secondary node)")
    return _connect(hosts["secondary"]["ipv4"], ssh_config_file)
