"""Build testinfra SSH hosts for the centralized_k0s cluster from `tofu output -json`.

The cluster injects the local SSH public key into each VM's ubuntu user via cloud-init, so we
connect over SSH using the matching private key. IPs come from the `hosts` output.
StrictHostKeyChecking is disabled — these are throwaway lab VMs whose host keys change every
`just up`.

Topology is variable (1+2 default / 3+3+HAProxy HA), so the **max** role set is enumerated as
skip-guarded fixtures (the netbox `agent` idiom): `controller-1`, `worker-1`, `worker-2` are always
present; `controller-2`, `controller-3`, `worker-3`, `haproxy` each `pytest.skip` when absent from
the `hosts` map. Every node runs an async node-prep oneshot; the fixtures poll its
`/var/lib/k0s-nodeprep/done` marker before yielding, and k0sctl forms the cluster post-apply.
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
# cloud-init reaches `done` fast (heavy tool/Vector installs run async in the node-prep oneshot,
# then k0sctl forms the cluster from the host). Give the marker a generous window.
READY_TIMEOUT = 1200
# The node-prep oneshot's success marker (written by the controller/worker cloud-init).
NODEPREP_MARKER = "/var/lib/k0s-nodeprep/done"

# tests/testinfra/ -> clusters/centralized_k0s/
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
def enabled_features(tofu_output):
    """Opt-in feature flags ({ha, cilium, netdata}) — drives skip-not-fail in the live suite."""
    return tofu_output["enabled_features"]["value"]


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
    raise TimeoutError(
        f"marker {path} not present after {timeout}s (node-prep failed?)"
    )


def _role_host(hosts, ssh_config_file, role, *, required):
    """Connect to a role VM + block on its node-prep marker. Skip cleanly when optional + absent."""
    if role not in hosts:
        if required:
            raise KeyError(f"required role {role} missing from hosts output")
        pytest.skip(f"role {role} absent from this topology (hosts={sorted(hosts)})")
    host = _connect(hosts[role]["ipv4"], ssh_config_file)
    _wait_for_marker(host, NODEPREP_MARKER)
    return host


# --- Always-present roles (default 1+2 topology) ----------------------------


@pytest.fixture(scope="session")
def controller_1(hosts, ssh_config_file):
    return _role_host(hosts, ssh_config_file, "controller-1", required=True)


@pytest.fixture(scope="session")
def worker_1(hosts, ssh_config_file):
    return _role_host(hosts, ssh_config_file, "worker-1", required=True)


@pytest.fixture(scope="session")
def worker_2(hosts, ssh_config_file):
    return _role_host(hosts, ssh_config_file, "worker-2", required=True)


# --- HA-only roles: skip cleanly when the topology doesn't include them ------


@pytest.fixture(scope="session")
def controller_2(hosts, ssh_config_file):
    return _role_host(hosts, ssh_config_file, "controller-2", required=False)


@pytest.fixture(scope="session")
def controller_3(hosts, ssh_config_file):
    return _role_host(hosts, ssh_config_file, "controller-3", required=False)


@pytest.fixture(scope="session")
def worker_3(hosts, ssh_config_file):
    return _role_host(hosts, ssh_config_file, "worker-3", required=False)


@pytest.fixture(scope="session")
def haproxy(hosts, ssh_config_file):
    """The HAProxy edge VM — only exists in HA mode (>1 controller); skip otherwise.

    HAProxy has no k0s node-prep oneshot, so connect without the marker poll.
    """
    if "haproxy" not in hosts:
        pytest.skip("HAProxy absent (single-controller topology)")
    return _connect(hosts["haproxy"]["ipv4"], ssh_config_file)


# --- Convenience collections ------------------------------------------------


@pytest.fixture(scope="session")
def all_nodes(request, hosts):
    """All k0s node role fixtures present in this topology (controllers + workers, no HAProxy)."""
    out = {}
    for role in sorted(hosts):
        if role == "haproxy":
            continue
        out[role] = request.getfixturevalue(role.replace("-", "_"))
    return out


@pytest.fixture(scope="session")
def controllers(request, hosts):
    """All controller role fixtures present in this topology."""
    return {
        role: request.getfixturevalue(role.replace("-", "_"))
        for role in sorted(hosts)
        if role.startswith("controller-")
    }


# --- Cross-cluster log-shipping coordinates (skip-guard for enrichment) ------


@pytest.fixture(scope="session")
def cross_cluster_enabled(tofu_output):
    """True when Vector ships cross-cluster (log_shipping_target or openobserve_endpoint set)."""
    return tofu_output["cross_cluster_enabled"]["value"]


def _load_cross_cluster_tfvars():
    """Best-effort read of the up-connected wiring file for live shipping coordinates."""
    path = CLUSTER_DIR / ".cross-cluster.auto.tfvars.json"
    if path.exists():
        try:
            return json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            return {}
    return {}


@pytest.fixture(scope="session")
def openobserve(cross_cluster_enabled):
    """OpenObserve coordinates for the pod-log enrichment assertion.

    The up-connected wiring file carries `openobserve_endpoint`; the org/stream/password are not in
    the cross-cluster var contract, so they come from env (K0S_OO_ORG/STREAM/PASSWORD) with sane
    defaults. Skips cleanly whenever shipping is off or the coordinates are incomplete — this is the
    real-record enrichment proof, not a smoke test.
    """
    if not cross_cluster_enabled:
        pytest.skip("cross-cluster shipping disabled (no OpenObserve endpoint)")
    tf = _load_cross_cluster_tfvars()
    endpoint = os.environ.get("K0S_OO_ENDPOINT") or tf.get("openobserve_endpoint", "")
    password = os.environ.get("K0S_OO_PASSWORD", "")
    org = os.environ.get("K0S_OO_ORG", "default")
    stream = os.environ.get("K0S_OO_STREAM", "k0s_pods")
    user = os.environ.get("K0S_OO_USER", "admin@example.com")
    if not endpoint or not password:
        pytest.skip(
            "OpenObserve coords incomplete — set K0S_OO_ENDPOINT/K0S_OO_PASSWORD "
            "(org/stream default to default/k0s_pods) to run the enrichment assertion"
        )
    return {
        "base_url": f"http://{endpoint}",
        "org": org,
        "stream": stream,
        "user": user,
        "password": password,
    }


@pytest.fixture(scope="session")
def log_shipping_host():
    """Host of the centralized_logging syslog-ng collector (for the /var/log/remote archival check).

    Read from the up-connected wiring file or K0S_LOG_HOST; skip when unavailable.
    """
    tf = _load_cross_cluster_tfvars()
    target = os.environ.get("K0S_LOG_HOST") or tf.get("log_shipping_target", "")
    if not target:
        pytest.skip("no log_shipping_target wired — cannot check logging /var/log/remote")
    return target.split(":")[0]
