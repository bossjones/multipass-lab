"""Cross-cluster telemetry wiring on the pki VMs (specs/cross-cluster.md).

These checks auto-skip unless the cluster was brought up wired (via `just up-connected`): they
key off the presence of the syslog shipper drop-in / the otelcol agent config, so a plain
`just verify centralized_pki` on an isolated cluster stays green. The full end-to-end delivery
check (log line actually reaching the logging hub) lives in `just verify-connected`, which spans
both clusters.
"""

import pytest

SHIP_CONF = "/etc/syslog-ng/conf.d/10-ship.conf"
OTEL_CONF = "/etc/otelcol-contrib/config.yaml"


@pytest.fixture(params=["ca", "services"])
def pki_vm(request, ca, services):
    return {"ca": ca, "services": services}[request.param]


def test_syslog_shipper_active_when_wired(pki_vm):
    if not pki_vm.file(SHIP_CONF).exists:
        pytest.skip("log shipping not wired (log_shipping_target unset)")
    assert pki_vm.service("syslog-ng").is_running
    conf = pki_vm.file(SHIP_CONF).content_string
    assert "d_central" in conf, "shipper must define the central destination"


def test_otel_agent_active_when_wired(pki_vm):
    if not pki_vm.file(OTEL_CONF).exists:
        pytest.skip("OTLP push not wired (openobserve_endpoint unset)")
    assert pki_vm.service("otelcol-contrib").is_running
    conf = pki_vm.file(OTEL_CONF).content_string
    assert "otlphttp/host" in conf, "agent must define the OpenObserve OTLP exporter"
