"""Hermetic tests for _dns_common (shared centralized_dns CLI helpers)."""

import _dns_common as dc


def test_parse_tofu_output_extracts_ip_and_flags():
    doc = {
        "server_ipv4": {"value": "10.1.2.3"},
        "enabled_flags": {"value": ["enable_node_exporter", "enable_adguard_exporter"]},
    }
    ip, flags = dc.parse_tofu_output(doc)
    assert ip == "10.1.2.3"
    assert flags == {"enable_node_exporter", "enable_adguard_exporter"}


def test_parse_tofu_output_prefers_dns_endpoint_over_server_ipv4():
    # HA mode: dns_endpoint (the VIP) must win over the legacy server_ipv4 output.
    doc = {
        "server_ipv4": {"value": None},
        "dns_endpoint": {"value": "10.10.10.99"},
        "enabled_flags": {"value": []},
    }
    ip, _flags = dc.parse_tofu_output(doc)
    assert ip == "10.10.10.99"


def test_parse_hosts_and_is_ha():
    single = {"hosts": {"value": {"server": {"name": "x", "ipv4": "10.0.0.1"}}}}
    assert dc.parse_hosts(single) == {"server": {"name": "x", "ipv4": "10.0.0.1"}}
    assert dc.is_ha(single) is False

    ha = {
        "hosts": {
            "value": {
                "primary": {"name": "p", "ipv4": "10.0.0.2"},
                "secondary": {"name": "s", "ipv4": "10.0.0.3"},
            }
        },
        "enabled_features": {"value": {"ha": True}},
    }
    assert set(dc.parse_hosts(ha)) == {"primary", "secondary"}
    assert dc.is_ha(ha) is True


def test_resolve_target_prefers_explicit_url_and_skips_tofu():
    called = {"n": 0}

    def boom(_chdir):
        called["n"] += 1
        raise AssertionError("tofu must not run when server_url is given")

    t = dc.resolve_target(port=3000, server_url="http://x:3000/", runner=boom)
    assert t.base_url == "http://x:3000"
    assert called["n"] == 0


def test_resolve_target_from_tofu_builds_url():
    def fake(_chdir):
        return {"server_ipv4": {"value": "10.9.9.9"}, "enabled_flags": {"value": []}}

    t = dc.resolve_target(port=9167, runner=fake)
    assert t.base_url == "http://10.9.9.9:9167"
    assert t.ip == "10.9.9.9"


def test_resolve_target_target_output_override():
    def fake(_chdir):
        return {
            "dns_endpoint": {"value": "10.10.10.99"},
            "dns_rewrite_target": {"value": "10.0.0.2"},
            "enabled_flags": {"value": []},
        }

    # Default (no target_output): dns_endpoint (VIP).
    t = dc.resolve_target(port=3000, runner=fake)
    assert t.ip == "10.10.10.99"

    # AdGuard web API / config edits must hit the origin, not the VIP.
    t = dc.resolve_target(port=3000, runner=fake, target_output="dns_rewrite_target")
    assert t.ip == "10.0.0.2"
    assert t.base_url == "http://10.0.0.2:3000"


def test_resolve_credentials_precedence():
    # flag wins
    assert dc.resolve_credentials(
        "u", "p", default_user="d", default_password="dp", env={}
    ) == ("u", "p")
    # env next
    assert dc.resolve_credentials(
        None,
        None,
        user_env="AU",
        pass_env="AP",
        default_user="d",
        default_password="dp",
        env={"AU": "eu", "AP": "ep"},
    ) == ("eu", "ep")
    # default last
    assert dc.resolve_credentials(
        None, None, default_user="d", default_password="dp", env={}
    ) == ("d", "dp")


def test_parse_prometheus_metrics_strips_labels_and_comments():
    text = """
# HELP unbound_up Whether the scrape succeeded
# TYPE unbound_up gauge
unbound_up 1
unbound_queries_total 42
unbound_cache_hits_total{thread="0"} 10
bad_line_without_value
""".strip()
    m = dc.parse_prometheus_metrics(text)
    assert m["unbound_up"] == 1.0
    assert m["unbound_queries_total"] == 42.0
    assert m["unbound_cache_hits_total"] == 10.0
    assert "bad_line_without_value" not in m


def test_check_report_exit_code():
    r = dc.CheckReport()
    r.add("a", True)
    r.skip("b")
    assert r.passed
    assert r.exit_code == 0
    r.add("c", False, "boom")
    assert not r.passed
    assert r.exit_code == dc.CHECK_FAIL_EXIT
