"""Cross-cluster telemetry wiring on the DNS VM (specs/cross-cluster.md).

These checks auto-skip unless the cluster was wired (via `just up-connected`): they key off the
presence of the syslog shipper drop-in / the otelcol agent config, so a plain
`just verify centralized_dns` on an isolated cluster stays green. This cluster boots FIRST, so
its own log-shipping is hot-pushed after the hubs exist — hence the wiring may arrive slightly
later than the exporters.
"""

import pytest

SHIP_CONF = "/etc/syslog-ng/conf.d/10-ship.conf"
OTEL_CONF = "/etc/otelcol-contrib/config.yaml"


def test_syslog_shipper_active_when_wired(server):
    if not server.file(SHIP_CONF).exists:
        pytest.skip("log shipping not wired (log_shipping_target unset)")
    assert server.service("syslog-ng").is_running
    assert "d_central" in server.file(SHIP_CONF).content_string


def test_otel_agent_active_when_wired(server):
    if not server.file(OTEL_CONF).exists:
        pytest.skip("OTLP push not wired (openobserve_endpoint unset)")
    assert server.service("otelcol-contrib").is_running
    assert "otlphttp/host" in server.file(OTEL_CONF).content_string
