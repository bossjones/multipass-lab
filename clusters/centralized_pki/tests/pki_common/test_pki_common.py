"""Hermetic unit tests for _pki_common (pure tofu-output parsing + target resolution).

The TLS-chain helpers (fetch_leaf_cert_pem / verify_chains_to) are exercised against a real
self-signed fixture in the tls suite (tests/tls/), which already needs cryptography.
"""

import _pki_common as pc


def _tofu_output():
    return {
        "ca_ipv4": {"value": "10.0.0.5"},
        "services_ipv4": {"value": "10.0.0.6"},
        "enabled_flags": {"value": ["enable_node_exporter"]},
        "domain": {"value": "lab.example.com"},
    }


def test_parse_tofu_output_extracts_ips_flags_domain():
    parsed = pc.parse_tofu_output(_tofu_output())
    assert parsed["ca_ipv4"] == "10.0.0.5"
    assert parsed["services_ipv4"] == "10.0.0.6"
    assert parsed["enabled_flags"] == {"enable_node_exporter"}
    assert parsed["domain"] == "lab.example.com"


def test_parse_tofu_output_tolerates_missing_flags():
    parsed = pc.parse_tofu_output({"ca_ipv4": {"value": "1.2.3.4"}})
    assert parsed["ca_ipv4"] == "1.2.3.4"
    assert parsed["enabled_flags"] == set()
    assert parsed["services_ipv4"] is None


def test_resolve_target_ca_role_builds_https_url():
    t = pc.resolve_target(role="ca", port=9000, runner=lambda _chdir: _tofu_output())
    assert t.base_url == "https://10.0.0.5:9000"
    assert t.ip == "10.0.0.5"
    assert t.enabled_flags == {"enable_node_exporter"}
    assert t.domain == "lab.example.com"


def test_resolve_target_services_role_selects_services_ip():
    t = pc.resolve_target(role="services", port=443, runner=lambda _chdir: _tofu_output())
    assert t.base_url == "https://10.0.0.6:443"


def test_resolve_target_server_url_override_skips_tofu():
    def _boom(_chdir):
        raise AssertionError("tofu must not be invoked when server_url is given")

    t = pc.resolve_target(
        role="ca", port=9000, server_url="http://127.0.0.1:5555/", runner=_boom
    )
    assert t.base_url == "http://127.0.0.1:5555"
    assert t.enabled_flags == set()


def test_resolve_target_url_env_override(monkeypatch):
    t = pc.resolve_target(
        role="services",
        port=443,
        url_env="PKI_TEST_URL",
        env={"PKI_TEST_URL": "http://env-host:8443"},
        runner=lambda _chdir: (_ for _ in ()).throw(AssertionError("no tofu")),
    )
    assert t.base_url == "http://env-host:8443"


def test_resolve_credentials_precedence():
    # flag > env > default
    assert pc.resolve_credentials(
        "flaguser", None, pass_env="P", default_user="d", default_password="dp",
        env={"P": "envpass"},
    ) == ("flaguser", "envpass")
    assert pc.resolve_credentials(
        None, None, user_env="U", pass_env="P", default_user="d", default_password="dp",
        env={},
    ) == ("d", "dp")


def test_checkreport_exit_code_and_dict():
    r = pc.CheckReport()
    r.add("a", True, "ok")
    r.skip("b", "n/a")
    assert r.passed is True
    assert r.exit_code == 0
    r.add("c", False, "boom")
    assert r.passed is False
    assert r.exit_code == pc.CHECK_FAIL_EXIT
    d = r.to_dict()
    assert d["ok"] is False
    assert {c["name"] for c in d["checks"]} == {"a", "b", "c"}
