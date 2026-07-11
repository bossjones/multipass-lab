"""Hermetic behavior tests for unbound_cli.

Drives the CLI via typer's CliRunner against a pytest-httpserver serving a canned
unbound_exporter /metrics body. `--server-url` avoids any `tofu` invocation.
"""

import json
import subprocess

import unbound_cli as ub
from typer.testing import CliRunner

runner = CliRunner()

METRICS_UP = """
# HELP unbound_up Whether scraping Unbound succeeded
# TYPE unbound_up gauge
unbound_up 1
unbound_queries_total 128
unbound_cache_hits_total 90
unbound_cache_misses_total 38
unbound_memory_caches_bytes 1048576
""".strip()

METRICS_DOWN = "unbound_up 0"


def _run(base, *args):
    return runner.invoke(ub.app, ["--server-url", base, *args])


class _FakeCompleted:
    def __init__(self, stdout="", stderr="", returncode=0):
        self.stdout = stdout
        self.stderr = stderr
        self.returncode = returncode


def _fake_subprocess_run(tofu_json=None):
    """A `subprocess.run` stand-in for the `tofu output -json` call in `_dns_common`."""

    def _run(cmd, **kwargs):
        if cmd[0] == "tofu":
            return _FakeCompleted(stdout=json.dumps(tofu_json or {}))
        raise AssertionError(f"unexpected subprocess.run call: {cmd}")

    return _run


def test_stats_renders_key_metrics_json(httpserver):
    httpserver.expect_request("/metrics").respond_with_data(METRICS_UP)
    r = _run(httpserver.url_for(""), "--json", "stats")
    assert r.exit_code == 0, r.output
    doc = json.loads(r.output)
    assert doc["unbound_queries_total"] == 128
    assert doc["unbound_cache_hits_total"] == 90


def test_check_passes_when_unbound_up(httpserver):
    httpserver.expect_request("/metrics").respond_with_data(METRICS_UP)
    r = _run(httpserver.url_for(""), "--json", "check")
    assert r.exit_code == 0, r.output
    doc = json.loads(r.output)
    assert doc["ok"] is True
    names = {c["name"]: c["status"] for c in doc["checks"]}
    assert names["unbound reachable (unbound_up=1)"] == "pass"


def test_check_fails_when_unbound_down(httpserver):
    httpserver.expect_request("/metrics").respond_with_data(METRICS_DOWN)
    r = _run(httpserver.url_for(""), "--json", "check")
    assert r.exit_code == ub.dc.CHECK_FAIL_EXIT, r.output
    assert json.loads(r.output)["ok"] is False


def test_check_fails_when_exporter_unreachable():
    # Nothing listening on this port -> transport error -> _die exit(1).
    r = _run("http://127.0.0.1:9", "--json", "check")
    assert r.exit_code != 0, r.output


# --- HA: --node targeting -----------------------------------------------------


def test_node_option_targets_specific_host(httpserver, monkeypatch):
    monkeypatch.setattr(ub, "PORT", httpserver.port)
    tofu_json = {
        "hosts": {"value": {"primary": {"name": "p", "ipv4": httpserver.host}}}
    }
    monkeypatch.setattr(subprocess, "run", _fake_subprocess_run(tofu_json))
    httpserver.expect_request("/metrics").respond_with_data(METRICS_UP)
    r = runner.invoke(ub.app, ["--node", "primary", "--json", "stats"])
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)["unbound_queries_total"] == 128


def test_node_not_in_hosts_dies(monkeypatch):
    tofu_json = {"hosts": {"value": {"primary": {"name": "p", "ipv4": "10.0.0.2"}}}}
    monkeypatch.setattr(subprocess, "run", _fake_subprocess_run(tofu_json))
    r = runner.invoke(ub.app, ["--node", "tertiary", "stats"])
    assert r.exit_code == 1, r.output
    assert "not in tofu hosts output" in r.output


# --- HA: fan-out inside `check` -----------------------------------------------


def test_check_ha_mode_both_nodes_up_passes(httpserver, monkeypatch):
    monkeypatch.setattr(ub, "PORT", httpserver.port)
    tofu_json = {
        "hosts": {
            "value": {
                "primary": {"name": "p", "ipv4": httpserver.host},
                "secondary": {"name": "s", "ipv4": httpserver.host},
            }
        },
        "enabled_features": {"value": {"ha": True}},
        "dns_endpoint": {"value": httpserver.host},
        "enabled_flags": {"value": []},
    }
    monkeypatch.setattr(subprocess, "run", _fake_subprocess_run(tofu_json))
    httpserver.expect_request("/metrics").respond_with_data(METRICS_UP)
    r = runner.invoke(ub.app, ["--json", "check"])
    assert r.exit_code == 0, r.output
    doc = json.loads(r.output)
    assert doc["ok"] is True
    names = {c["name"]: c["status"] for c in doc["checks"]}
    assert names["primary unbound_up=1"] == "pass"
    assert names["secondary unbound_up=1"] == "pass"


def test_check_ha_mode_one_node_down_fails(httpserver, monkeypatch):
    monkeypatch.setattr(ub, "PORT", httpserver.port)
    tofu_json = {
        "hosts": {
            "value": {
                "primary": {"name": "p", "ipv4": httpserver.host},
                # 127.0.0.2 is loopback but nothing listens there -> connection refused.
                "secondary": {"name": "s", "ipv4": "127.0.0.2"},
            }
        },
        "enabled_features": {"value": {"ha": True}},
        "dns_endpoint": {"value": httpserver.host},
        "enabled_flags": {"value": []},
    }
    monkeypatch.setattr(subprocess, "run", _fake_subprocess_run(tofu_json))
    httpserver.expect_request("/metrics").respond_with_data(METRICS_UP)
    r = runner.invoke(ub.app, ["--json", "--timeout", "2", "check"])
    assert r.exit_code == ub.dc.CHECK_FAIL_EXIT, r.output
    doc = json.loads(r.output)
    names = {c["name"]: c["status"] for c in doc["checks"]}
    assert names["primary unbound_up=1"] == "pass"
    assert names["secondary unbound_up=1"] == "fail"


def test_check_single_mode_skips_ha_block(httpserver, monkeypatch):
    monkeypatch.setattr(ub, "PORT", httpserver.port)
    tofu_json = {
        "hosts": {"value": {"server": {"name": "x", "ipv4": httpserver.host}}},
        "dns_endpoint": {"value": httpserver.host},
        "enabled_flags": {"value": []},
    }
    monkeypatch.setattr(subprocess, "run", _fake_subprocess_run(tofu_json))
    httpserver.expect_request("/metrics").respond_with_data(METRICS_UP)
    r = runner.invoke(ub.app, ["--json", "check"])
    assert r.exit_code == 0, r.output
    doc = json.loads(r.output)
    names = {c["name"] for c in doc["checks"]}
    assert "primary unbound_up=1" not in names
    assert "secondary unbound_up=1" not in names
