"""Live cluster health over SSH (`just verify centralized_k0s`).

The k0s cluster is formed post-apply by k0sctl, so these run after the node-prep marker AND the
bootstrap have settled. Node roles are parametrized over the MAX role set; a role absent from this
topology skips cleanly (its fixture calls `pytest.skip`). Controllers run `--enable-worker`, so they
are Ready nodes too — the expected node count is controllers + workers.
"""

import json
import time

import pytest

# Max node role set (no HAProxy — it's not a k0s node). Absent roles skip via their fixtures.
NODE_ROLES = [
    "controller-1",
    "controller-2",
    "controller-3",
    "worker-1",
    "worker-2",
    "worker-3",
]
CONTROLLER_ROLES = ["controller-1", "controller-2", "controller-3"]

TOOLS = ["kubectl", "helm", "k9s", "stern", "etcdctl", "k0s"]
COMPLETIONS = ["_kubectl", "_helm", "_stern", "_k9s", "_k0s", "_etcdctl"]


def _fx(request, role):
    """Resolve a role's host fixture (hyphen -> underscore); skips if the role is absent."""
    return request.getfixturevalue(role.replace("-", "_"))


def _expected_node_count(hosts):
    return len([r for r in hosts if r.startswith(("controller-", "worker-"))])


# --- control plane ----------------------------------------------------------


@pytest.mark.parametrize("role", CONTROLLER_ROLES)
def test_k0s_status_running(request, role):
    """Each controller reports a Running k0s controller process."""
    host = _fx(request, role)
    res = host.run("sudo k0s status")
    assert res.rc == 0, f"`k0s status` failed on {role}: {res.stderr}"
    assert "Version" in res.stdout, f"k0s not reporting a version on {role}: {res.stdout}"


def test_all_nodes_ready(controller_1, hosts):
    """From controller-1: every node (controllers + workers) is Ready."""
    expected = _expected_node_count(hosts)
    deadline = time.time() + 300
    ready = 0
    while time.time() < deadline:
        res = controller_1.run("sudo k0s kubectl get nodes -o json")
        if res.rc == 0:
            nodes = json.loads(res.stdout)["items"]
            ready = sum(
                1
                for n in nodes
                for c in n["status"]["conditions"]
                if c["type"] == "Ready" and c["status"] == "True"
            )
            if ready >= expected and len(nodes) >= expected:
                break
        time.sleep(10)
    assert ready == expected, f"{ready}/{expected} nodes Ready"


# --- kubeconfig distributed to every node -----------------------------------


@pytest.mark.parametrize("role", NODE_ROLES)
def test_standalone_kubectl_as_ubuntu(request, role):
    """The admin kubeconfig is distributed to every node — `kubectl` works as the ubuntu user."""
    host = _fx(request, role)
    res = host.run("kubectl get nodes")
    assert res.rc == 0, f"standalone kubectl failed on {role} (kubeconfig not distributed?)"
    assert "Ready" in res.stdout, f"kubectl on {role} shows no Ready nodes"


# --- node tooling + shell UX ------------------------------------------------


@pytest.mark.parametrize("role", NODE_ROLES)
def test_tools_present(request, role):
    """kubectl / helm / k9s / stern / etcdctl / k0s are installed on every node."""
    host = _fx(request, role)
    for tool in TOOLS:
        assert host.run(f"command -v {tool}").rc == 0, f"{tool} missing on {role}"


@pytest.mark.parametrize("role", NODE_ROLES)
def test_zsh_default_shell_with_completions(request, role):
    """ubuntu's login shell is zsh with oh-my-zsh + per-tool completions installed."""
    host = _fx(request, role)
    passwd = host.run("getent passwd ubuntu").stdout
    assert passwd.rstrip().endswith("zsh"), f"ubuntu shell is not zsh on {role}: {passwd}"
    assert host.run("test -d /home/ubuntu/.oh-my-zsh").rc == 0, f"oh-my-zsh missing on {role}"
    for comp in COMPLETIONS:
        assert (
            host.run(f"test -f /home/ubuntu/.oh-my-zsh/completions/{comp}").rc == 0
        ), f"zsh completion {comp} missing on {role}"


# --- control-plane FUNCTIONAL health (backlog #6: the suite was green while broken) ------
# `just verify` passed 20/20 while konnectivity-agent was 0/1 and the metrics API 503'd. These two
# assertions close that gap: "green from source" must mean the API->node tunnel actually works, not
# just that nodes report Ready. A broken externalAddress/CoreDNS resolution (k0sctl's fix) leaves the
# konnectivity tunnel down, and its only symptom is `kubectl top`/`logs`/`exec` returning 503
# "No agent available" — which nothing exercised before.


def _all_pods_ready(pods):
    """True only when every pod has containerStatuses and all containers are ready."""
    if not pods:
        return False
    for p in pods:
        statuses = p["status"].get("containerStatuses")
        if not statuses or not all(cs.get("ready") for cs in statuses):
            return False
    return True


def test_konnectivity_agents_ready(controller_1):
    """Every konnectivity-agent pod (the apiserver->node tunnel) is Ready.

    0/1 agents means `kubectl top`/`logs`/`exec` 503 with "No agent available" — the live defect
    that slipped through before (backlog #6)."""
    deadline = time.time() + 240
    pods = []
    while time.time() < deadline:
        res = controller_1.run(
            "sudo k0s kubectl get pods -n kube-system "
            "-l k8s-app=konnectivity-agent -o json"
        )
        if res.rc == 0:
            pods = json.loads(res.stdout)["items"]
            if _all_pods_ready(pods):
                return
        time.sleep(10)
    ready = sum(1 for p in pods if _all_pods_ready([p]))
    pytest.fail(
        f"konnectivity-agent pods not all Ready ({ready}/{len(pods)}) — "
        "apiserver->node tunnel down (metrics/exec/logs will 503)"
    )


def test_metrics_api_serves_node_metrics(controller_1, hosts):
    """metrics.k8s.io serves node metrics (`kubectl top nodes` returns rows), not 503.

    A working konnectivity tunnel is a prerequisite; `top nodes` returning "No agent available" /
    "Metrics API not available" is exactly the symptom the old suite missed."""
    expected = _expected_node_count(hosts)
    deadline = time.time() + 300
    last = ""
    while time.time() < deadline:
        res = controller_1.run("sudo k0s kubectl top nodes --no-headers")
        last = (res.stderr or res.stdout).strip()
        if res.rc == 0:
            rows = [ln for ln in res.stdout.splitlines() if ln.strip()]
            if len(rows) >= expected:
                return
        time.sleep(10)
    pytest.fail(
        f"metrics API did not serve node metrics for {expected} nodes "
        f"(kubectl top nodes): {last}"
    )


# --- CoreDNS durability (backlog #7) ----------------------------------------
# A broken spec.api.externalAddress / self-referential upstream makes CoreDNS hit the
# `plugin/loop` detector and crash-loop, taking cluster DNS down intermittently. The old suite
# never read CoreDNS's own logs, so it stayed green. These assert CoreDNS is Ready AND its logs are
# free of the loop signature — plus (via test_metrics_api_serves_node_metrics above) that the
# metrics API still answers, since a DNS flap knocks it out too.


def test_coredns_pods_ready(controller_1):
    """Every CoreDNS pod (k8s-app=kube-dns) is Ready — cluster DNS is up."""
    deadline = time.time() + 240
    pods = []
    while time.time() < deadline:
        res = controller_1.run(
            "sudo k0s kubectl get pods -n kube-system -l k8s-app=kube-dns -o json"
        )
        if res.rc == 0:
            pods = json.loads(res.stdout)["items"]
            if _all_pods_ready(pods):
                return
        time.sleep(10)
    ready = sum(1 for p in pods if _all_pods_ready([p]))
    pytest.fail(f"CoreDNS pods not all Ready ({ready}/{len(pods)}) — cluster DNS down")


def test_coredns_no_plugin_loop(controller_1):
    """CoreDNS logs carry NO `plugin/loop` line — the crash-loop signature of a self-referential
    upstream (broken externalAddress/resolv.conf). Zero occurrences in the last 200 lines."""
    res = controller_1.run(
        "sudo k0s kubectl -n kube-system logs -l k8s-app=kube-dns --tail=200"
    )
    assert res.rc == 0, f"could not read CoreDNS logs: {res.stderr}"
    loops = res.stdout.count("plugin/loop")
    assert loops == 0, (
        f"CoreDNS logged `plugin/loop` {loops}x — DNS loop detector tripped "
        "(self-referential upstream; check spec.api.externalAddress / resolv.conf)"
    )


# --- kube-state-metrics readiness (backlog #8) ------------------------------
# `just verify` went green a 2nd time while a real component (KSM) was in CrashLoopBackOff — same
# node-Ready-only blind spot as konnectivity/CoreDNS. Assert the Deployment actually has an
# available replica, and that it serves kube_* on the NEW hostNetwork port 8082 (CORE moved KSM to
# --port=8082 / --telemetry-port=8083; do NOT probe the old 8080/8081).
KSM_METRICS_PORT = 8082


def test_kube_state_metrics_ready(controller_1):
    """The kube-state-metrics Deployment has exactly one available replica (not CrashLoopBackOff)."""
    deadline = time.time() + 300
    avail = "0"
    while time.time() < deadline:
        res = controller_1.run(
            "sudo k0s kubectl get deploy -n kube-system kube-state-metrics "
            "-o jsonpath='{.status.availableReplicas}'"
        )
        if res.rc == 0:
            avail = res.stdout.strip().strip("'") or "0"
            if avail == "1":
                return
        time.sleep(10)
    pytest.fail(
        f"kube-state-metrics availableReplicas={avail} (expected 1 — CrashLoopBackOff?)"
    )


def test_kube_state_metrics_serves_metrics(controller_1):
    """KSM (hostNetwork) serves kube_* on the new port 8082 from the node it landed on."""
    host_ip = ""
    deadline = time.time() + 120
    while time.time() < deadline:
        res = controller_1.run(
            "sudo k0s kubectl get pods -n kube-system "
            "-l app.kubernetes.io/name=kube-state-metrics "
            "-o jsonpath='{.items[0].status.hostIP}'"
        )
        host_ip = res.stdout.strip().strip("'")
        if res.rc == 0 and host_ip:
            break
        time.sleep(10)
    assert host_ip, "could not resolve the node kube-state-metrics landed on"

    deadline = time.time() + 120
    last = ""
    while time.time() < deadline:
        res = controller_1.run(
            f"curl -fsS http://{host_ip}:{KSM_METRICS_PORT}/metrics"
        )
        last = (res.stderr or "").strip()
        if res.rc == 0 and "kube_" in res.stdout:
            return
        time.sleep(10)
    pytest.fail(
        f"KSM :{KSM_METRICS_PORT}/metrics did not serve kube_* on {host_ip}: {last}"
    )
