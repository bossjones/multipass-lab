"""Coroot stack (opt-in, k0s node only): the eBPF observability platform is up and its UI serves.

The whole module is *skipped* (not failed) unless `enable_coroot` is on — read from the
`enabled_features` tofu output, mirroring how test_metrics skips disabled exporters. Coroot is
deployed declaratively in the k0s cloud-init (helm: coroot-operator + coroot-ce), so by the time
`just verify` runs the operator may still be pulling ClickHouse/Prometheus images — every check
polls with a generous deadline rather than asserting once. See specs/coroot.md.
"""

import time

import pytest

# k0s kubectl needs root (reads the admin kubeconfig under /var/lib/k0s).
KUBECTL = "sudo /usr/local/bin/k0s kubectl"
# Coroot bundles ClickHouse + Prometheus; first-boot image pulls on arm64 can be slow.
DEPLOY_TIMEOUT = 900


@pytest.fixture(scope="session")
def require_coroot(enabled_features):
    """Skip the whole module unless Coroot is enabled for this cluster."""
    if not enabled_features.get("coroot"):
        pytest.skip("enable_coroot is off")
    return True


@pytest.fixture(scope="session")
def require_ingress(enabled_features):
    if not enabled_features.get("ingress"):
        pytest.skip("enable_ingress is off")
    return True


def _wait_for_running(host, namespace, name_substr, timeout=DEPLOY_TIMEOUT):
    """Poll until a pod whose name contains `name_substr` reaches phase Running."""
    deadline = time.time() + timeout
    seen = ""
    jsonpath = (
        "{range .items[*]}{.metadata.name}{\" \"}{.status.phase}{\"\\n\"}{end}"
    )
    while time.time() < deadline:
        res = host.run(f"{KUBECTL} get pods -n {namespace} -o jsonpath='{jsonpath}'")
        seen = res.stdout or ""
        for line in seen.splitlines():
            parts = line.split()
            if len(parts) == 2 and name_substr in parts[0] and parts[1] == "Running":
                return
        time.sleep(10)
    pytest.fail(
        f"no Running pod matching '{name_substr}' in namespace '{namespace}' "
        f"after {timeout}s. Last seen:\n{seen}"
    )


def _wait_http_ok(host, url, timeout=DEPLOY_TIMEOUT):
    """Poll until `url` answers with a 2xx/3xx (curl from inside the VM)."""
    deadline = time.time() + timeout
    last = ""
    while time.time() < deadline:
        res = host.run(
            f"curl -s -o /dev/null -w '%{{http_code}}' --max-time 5 {url}"
        )
        last = res.stdout.strip()
        if last and last[0] in ("2", "3"):
            return last
        time.sleep(10)
    pytest.fail(f"{url} did not return 2xx/3xx after {timeout}s (last code: {last!r})")


@pytest.mark.parametrize(
    "name_substr",
    ["node-agent", "cluster-agent", "prometheus", "clickhouse"],
)
def test_coroot_stack_pods_running(require_coroot, k0s, name_substr):
    """The core Coroot components (eBPF node-agent + cluster-agent + Prometheus + ClickHouse)
    all reach Running in the `coroot` namespace."""
    _wait_for_running(k0s, "coroot", name_substr)


def test_coroot_operator_running(require_coroot, k0s):
    """The coroot-operator (which reconciles the Coroot CR) is up."""
    _wait_for_running(k0s, "coroot", "coroot-operator")


def test_openebs_ndm_removed(require_coroot, k0s):
    """OpenEBS NDM must be stripped by coroot-install.sh — it's the LocalPV-*device* scanner
    (unused here; all PVCs use openebs-hostpath) that leaked ~4Gi besteffort and OOM-killed the
    whole node. The hostpath localpv-provisioner must survive. See specs/centralized-logging-k0s-perf.md.
    """
    ds = k0s.run(f"{KUBECTL} -n openebs get daemonset openebs-ndm --ignore-not-found")
    assert "openebs-ndm" not in ds.stdout, (
        f"openebs-ndm DaemonSet must not exist (it leaks memory + OOM-kills the node). Got:\n{ds.stdout}"
    )
    # The provisioner that actually backs Coroot's PVCs must remain.
    prov = k0s.run(f"{KUBECTL} -n openebs get deploy openebs-localpv-provisioner --ignore-not-found")
    assert "openebs-localpv-provisioner" in prov.stdout, (
        "openebs-localpv-provisioner (hostpath) must survive the NDM strip — Coroot's PVCs need it"
    )


def test_node_memory_headroom(require_coroot, k0s):
    """Regression guard for the NDM OOM: the node must keep real memory headroom. With NDM gone
    the k0s VM sits at ~4Gi used of 8Gi; before the fix it was pinned at ~78Mi available."""
    res = k0s.run("free -m | awk '/^Mem:/ {print $7}'")  # 7th col = available MiB
    available = int(res.stdout.strip() or "0")
    assert available > 1000, (
        f"node available memory {available}MiB is dangerously low (<1000MiB) — possible OOM regression"
    )


def test_coroot_ui_reachable_via_nodeport(require_coroot, k0s, coroot_info):
    """The Coroot server serves its UI on the NodePort — proves the server pod is up + wired.

    A healthy server also proves node-agent data is flowing, since the UI is the server.
    """
    nodeport = coroot_info["nodeport"]
    _wait_http_ok(k0s, f"http://localhost:{nodeport}/")


def test_ingress_controller_running(require_coroot, require_ingress, k0s):
    """When ingress is enabled, the ingress-nginx controller is Running (hostNetwork on :80)."""
    _wait_for_running(k0s, "ingress-nginx", "ingress-nginx-controller")


def test_coroot_ui_reachable_via_ingress(require_coroot, require_ingress, k0s, coroot_info):
    """The Coroot UI answers through the ingress-nginx controller with the configured Host."""
    host_hdr = coroot_info["ingress_host"]
    _wait_http_ok(k0s, f"-H 'Host: {host_hdr}' http://localhost/")
