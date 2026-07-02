"""Build testinfra SSH hosts from `tofu output -json`.

The cluster injects the local SSH public key into each VM's ubuntu user via cloud-init, so we
connect over SSH using the matching private key. IPs come from the `hosts` output.
StrictHostKeyChecking is disabled — these are throwaway lab VMs whose host keys change every
`just up`. A `netbox` fixture exposes the API base URL + token so tests can cross-check the
registered objects directly against the REST API (the true self-registration proof).
"""

import json
import os
import subprocess
import time
from pathlib import Path

import pytest
import testinfra

# How long to wait for a VM to become SSH-reachable and finish cloud-init.
CONNECT_TIMEOUT = 180
CLOUD_INIT_TIMEOUT = 900
# cloud-init finishes fast (the NetBox bring-up + self-registration run asynchronously via
# systemd oneshots), so the fixtures then poll for each VM's readiness marker. netbox-docker
# pulls ~6 images + runs migrations on first boot, so give it a generous window.
READY_TIMEOUT = 1200

# tests/testinfra/ -> clusters/centralized_netbox/
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
def netbox(tofu_output):
    """NetBox API coordinates for host-side cross-checks.

    {base_url, token, cluster, vm_name, site, region, rack, host_device, prefix}.
    """
    return {
        "base_url": tofu_output["netbox_url"]["value"],
        "token": tofu_output["netbox_api_token"]["value"],
        "cluster": tofu_output["netbox_cluster_name"]["value"],
        "vm_name": tofu_output["registered_vm_name"]["value"],
        "site": tofu_output["netbox_site_name"]["value"],
        "region": tofu_output["netbox_region"]["value"],
        "rack": tofu_output["netbox_rack_name"]["value"],
        "host_device": tofu_output["netbox_host_device_name"]["value"],
        "prefix": tofu_output["netbox_prefix"]["value"],
    }


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

    # Block until cloud-init finishes (returns immediately if already done).
    host.run(f"timeout {CLOUD_INIT_TIMEOUT} cloud-init status --wait")
    return host


def _wait_for_marker(host, path, timeout=READY_TIMEOUT):
    """Poll until a readiness marker file exists (the async oneshot's success signal)."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if host.run(f"test -f {path}").rc == 0:
            return
        time.sleep(10)
    raise TimeoutError(f"marker {path} not present after {timeout}s (provisioning failed?)")


@pytest.fixture(scope="session")
def server(hosts, ssh_config_file):
    host = _connect(hosts["server"]["ipv4"], ssh_config_file)
    # netbox-stack.service brings up NetBox + bootstraps the cluster asynchronously.
    _wait_for_marker(host, "/var/lib/netbox-bootstrap/done")
    return host


@pytest.fixture(scope="session")
def client(hosts, ssh_config_file):
    host = _connect(hosts["client"]["ipv4"], ssh_config_file)
    # netbox-register.service self-registers this VM once the server's NetBox is up.
    _wait_for_marker(host, "/var/lib/netbox-register/done")
    return host
