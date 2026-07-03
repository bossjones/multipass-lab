"""Metrics layer — node_exporter on both VMs + the legacy syslog_ng_exporter on the controller.

Parametrized over the enabled_exporters output so a disabled exporter is skipped, not failed. All
listeners bind 0.0.0.0, so a future centralized_monitoring Prometheus can scrape these cross-VM.
"""

import pytest


def _curl_status(host, url):
    return host.run(f"curl -s -o /dev/null -w '%{{http_code}}' --max-time 10 {url}").stdout.strip()


def test_node_exporter_controller(controller, enabled_exporters):
    if "node" not in enabled_exporters:
        pytest.skip("node exporter disabled")
    assert _curl_status(controller, "http://localhost:9100/metrics") == "200"


def test_node_exporter_usg(usg, enabled_exporters):
    if "node" not in enabled_exporters:
        pytest.skip("node exporter disabled")
    assert _curl_status(usg, "http://localhost:9100/metrics") == "200"


def test_syslogng_exporter_serves_metrics(controller, enabled_exporters):
    """The legacy-CSV exporter (works on syslog-ng 3.28.1) serves syslog_ng_ series on :9577."""
    if "syslogng" not in enabled_exporters:
        pytest.skip("syslogng exporter disabled")
    out = controller.run("curl -s --max-time 10 http://localhost:9577/metrics")
    assert out.rc == 0
    assert "syslog_ng_" in out.stdout, out.stdout


def test_cross_vm_scrape_reachability(usg, hosts, enabled_exporters):
    """From the USG, the controller's node_exporter must be reachable (confirms the 0.0.0.0 bind
    that a future cross-cluster scrape depends on)."""
    if "node" not in enabled_exporters:
        pytest.skip("node exporter disabled")
    controller_ip = hosts["controller"]["ipv4"]
    assert _curl_status(usg, f"http://{controller_ip}:9100/metrics") == "200"
