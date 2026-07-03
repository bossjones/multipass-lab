"""Build testinfra SSH hosts from `tofu output -json`.

The cluster injects the local SSH public key into each VM's ubuntu user via cloud-init, so we
connect over SSH using the matching private key. IPs come from the `hosts` output.
StrictHostKeyChecking is disabled — these are throwaway lab VMs whose host keys change every
`just up`.
"""

import json
import os
import subprocess
import time
from pathlib import Path

import pytest
import testinfra

# How long to wait for a VM to become SSH-reachable and finish cloud-init. The services VM waits
# on the CA (root fetch) + several Docker pulls, so give cloud-init a generous ceiling.
CONNECT_TIMEOUT = 120
CLOUD_INIT_TIMEOUT = 900

# tests/testinfra/ -> clusters/centralized_pki/
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
def domain(tofu_output):
    """The DNS suffix (auth./vault./ca. live under this)."""
    return tofu_output["domain"]["value"]


@pytest.fixture(scope="session")
def enabled_flags(tofu_output):
    """Sorted list of active feature flags. Tests parametrize over this so a disabled feature
    is skipped (not failed)."""
    return tofu_output["enabled_flags"]["value"]


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

    # Block until provisioning finishes (returns immediately if already done).
    host.run(f"timeout {CLOUD_INIT_TIMEOUT} cloud-init status --wait")
    return host


@pytest.fixture(scope="session")
def docker_tools_enabled(tofu_output):
    """Whether the docker operator TUIs (wharf/oxker/dive) are installed. test_docker_tools
    skips when off."""
    return tofu_output["docker_tools_enabled"]["value"]


@pytest.fixture(scope="session")
def ca(hosts, ssh_config_file):
    return _connect(hosts["ca"]["ipv4"], ssh_config_file)


@pytest.fixture(scope="session")
def services(hosts, ssh_config_file):
    return _connect(hosts["services"]["ipv4"], ssh_config_file)
