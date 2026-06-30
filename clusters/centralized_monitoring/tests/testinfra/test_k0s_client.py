"""k0s-client VM: k0s healthy + each enabled OS/host exporter listening on its port.

Port checks are parametrized over `enabled_exporters` so a disabled exporter is
skipped, not failed.
"""

import time

import pytest

# enable_* flag -> host port the exporter listens on (client side).
CLIENT_FLAG_PORTS = {
    "enable_node_exporter": 9100,
    "enable_cadvisor": 8080,
    "enable_process_exporter": 9256,
    "enable_netdata": 19999,
    "enable_nut_exporter": 9199,
    "enable_nftables_exporter": 9630,
    "enable_filestat_exporter": 9943,
    "enable_osquery_exporter": 9450,
    "enable_ebpf_exporter": 9435,
    "enable_texporter": 9101,
    "enable_ffmpeg_exporter": 9618,
    "enable_script_exporter": 9469,
}


def test_k0s_status_healthy(k0s):
    assert k0s.run("sudo k0s status").rc == 0


@pytest.mark.parametrize("flag", list(CLIENT_FLAG_PORTS))
def test_enabled_client_exporter_port(k0s, enabled_exporters, flag):
    if flag not in enabled_exporters:
        pytest.skip(f"{flag} disabled")
    port = CLIENT_FLAG_PORTS[flag]
    _wait_listening(k0s, port)


def test_kube_state_metrics_reachable(k0s, enabled_exporters):
    if "enable_kube_state_metrics" not in enabled_exporters:
        pytest.skip("enable_kube_state_metrics disabled")
    # kube-state-metrics runs as a hostNetwork Deployment in kube-system; assert it is available.
    deadline = time.time() + 240
    while time.time() < deadline:
        res = k0s.run(
            "sudo k0s kubectl get deploy kube-state-metrics -n kube-system "
            "-o jsonpath='{.status.availableReplicas}'"
        )
        if res.rc == 0 and res.stdout.strip() not in ("", "0"):
            return
        time.sleep(10)
    pytest.fail("kube-state-metrics deployment never became available")


def _wait_listening(host, port, timeout=180):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if host.socket(f"tcp://0.0.0.0:{port}").is_listening:
            return
        time.sleep(5)
    pytest.fail(f"nothing listening on :{port} after {timeout}s")
