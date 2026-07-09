"""Live Vector log-shipping checks (`just verify centralized_k0s`).

One Vector agent per node ships host/k0s logs as syslog to centralized_logging and structured pod
logs (path-parsed, NO K8s API) to the monitoring hub's OpenObserve. The headline assertion is
**enrichment**: an actual OpenObserve record whose namespace/pod/container are POPULATED (the VRL
path-parse worked) — not merely "a record appears". Cross-cluster assertions skip cleanly when
shipping is unwired.
"""

import time

import httpx
import pytest
import testinfra

NODE_ROLES = [
    "controller-1",
    "controller-2",
    "controller-3",
    "worker-1",
    "worker-2",
    "worker-3",
]


def _fx(request, role):
    return request.getfixturevalue(role.replace("-", "_"))


# --- Vector agent present + collecting on every node ------------------------


@pytest.mark.parametrize("role", NODE_ROLES)
def test_vector_service_running(request, role):
    """Vector runs on every node (installed unconditionally — collection is always on)."""
    host = _fx(request, role)
    assert host.run("systemctl is-active vector").stdout.strip() == "active", (
        f"vector service not active on {role}"
    )


@pytest.mark.parametrize("role", NODE_ROLES)
def test_vector_config_has_path_parse_no_k8s_api(request, role):
    """The deployed Vector config VRL-parses the pod path (ns/pod/container) and never uses the
    kubernetes_logs source (locked decision — it needs API access Vector lacks at boot)."""
    host = _fx(request, role)
    cfg = host.run("sudo grep -R -l parse_regex /etc/vector 2>/dev/null").stdout.strip()
    assert cfg, f"no Vector config with a VRL parse_regex found under /etc/vector on {role}"
    body = host.run(f"sudo cat {cfg.splitlines()[0]}").stdout
    assert "namespace" in body and "container" in body, (
        f"Vector config on {role} does not extract namespace/container"
    )
    assert "/var/log/pods" in body, f"Vector config on {role} does not read /var/log/pods"
    assert "kubernetes_logs" not in body, (
        f"Vector config on {role} uses the forbidden kubernetes_logs source"
    )


@pytest.mark.parametrize("role", NODE_ROLES)
def test_pod_log_files_present(request, role):
    """kubelet writes pod logs under /var/log/pods on every node (Vector's file source input)."""
    host = _fx(request, role)
    deadline = time.time() + 180
    while time.time() < deadline:
        if host.run("sudo sh -c 'ls /var/log/pods/*/*/*.log' >/dev/null 2>&1").rc == 0:
            return
        time.sleep(10)
    pytest.fail(f"no /var/log/pods/*/*/*.log files on {role} after 180s")


# --- ENRICHMENT: a real OpenObserve record with populated ns/pod/container ---


def test_openobserve_pod_log_enrichment(openobserve):
    """Query OpenObserve for a pod-log record and assert namespace/pod/container are POPULATED.

    This is the enrichment proof: it fails if records arrive but the VRL path-parse left the fields
    empty (i.e. structure without meaning). Skips when shipping is unwired (see the openobserve
    fixture).
    """
    now_us = int(time.time() * 1_000_000)
    start_us = now_us - 3600 * 1_000_000
    stream = openobserve["stream"]
    body = {
        "query": {
            "sql": (
                f'SELECT namespace, pod, container FROM "{stream}" '
                "WHERE namespace IS NOT NULL AND namespace != '' "
                "AND container IS NOT NULL AND container != '' LIMIT 5"
            ),
            "start_time": start_us,
            "end_time": now_us,
            "size": 5,
        }
    }
    auth = (openobserve["user"], openobserve["password"])
    url = f"{openobserve['base_url']}/api/{openobserve['org']}/_search"

    hits = []
    deadline = time.time() + 300
    with httpx.Client(timeout=20) as client:
        while time.time() < deadline:
            try:
                resp = client.post(url, json=body, auth=auth)
            except httpx.HTTPError:
                time.sleep(10)
                continue
            if resp.status_code == 200:
                hits = resp.json().get("hits", [])
                if hits:
                    break
            time.sleep(10)

    assert hits, f"no enriched pod-log records in OpenObserve stream {stream} within 300s"
    enriched = [
        h for h in hits if h.get("namespace") and h.get("pod") and h.get("container")
    ]
    assert enriched, (
        f"records reached OpenObserve but namespace/pod/container are empty — "
        f"VRL path-parse enrichment failed: {hits[0]}"
    )


# --- ARCHIVAL: a syslog copy reaches centralized_logging's /var/log/remote ---


def test_syslog_archival_on_logging(log_shipping_host, hosts, ssh_config_file):
    """A syslog line from a k0s node lands in the logging hub's /var/log/remote (keep-hostname
    folders it by node hostname). Skips when no log_shipping_target is wired."""
    logging_host = testinfra.get_host(
        f"ssh://ubuntu@{log_shipping_host}", ssh_config=ssh_config_file
    )
    node_name = hosts["controller-1"]["name"]
    deadline = time.time() + 300
    while time.time() < deadline:
        res = logging_host.run(
            f"sudo grep -rl -- {node_name} /var/log/remote/ 2>/dev/null"
        )
        if res.rc == 0 and res.stdout.strip():
            return
        time.sleep(10)
    pytest.fail(
        f"no syslog from {node_name} in {log_shipping_host}:/var/log/remote within 300s"
    )
