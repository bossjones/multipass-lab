"""Build testinfra SSH hosts from `tofu output -json`.

The cluster injects the local SSH public key into each VM's ubuntu user via
cloud-init, so we connect over SSH using the matching private key. IPs come from
the `hosts` output. StrictHostKeyChecking is disabled — these are throwaway lab VMs
whose host keys change every `just up`.
"""

import json
import os
import subprocess
from pathlib import Path

import pytest
import testinfra

# tests/testinfra/ -> clusters/centralized_logging/
CLUSTER_DIR = Path(__file__).resolve().parents[2]
SSH_KEY = os.path.expanduser(
    os.environ.get("CLUSTER_SSH_KEY", "~/.ssh/id_ed25519")
)


@pytest.fixture(scope="session")
def hosts():
    """Return the cluster `hosts` output: {role: {name, ipv4}}."""
    raw = subprocess.run(
        ["tofu", f"-chdir={CLUSTER_DIR}", "output", "-json"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return json.loads(raw)["hosts"]["value"]


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
    return testinfra.get_host(f"ssh://ubuntu@{ip}", ssh_config=ssh_config_file)


@pytest.fixture(scope="session")
def central(hosts, ssh_config_file):
    return _connect(hosts["central"]["ipv4"], ssh_config_file)


@pytest.fixture(scope="session")
def k0s(hosts, ssh_config_file):
    return _connect(hosts["k0s"]["ipv4"], ssh_config_file)


@pytest.fixture(scope="session")
def docker(hosts, ssh_config_file):
    return _connect(hosts["docker"]["ipv4"], ssh_config_file)
