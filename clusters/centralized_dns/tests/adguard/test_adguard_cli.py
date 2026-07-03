"""Hermetic behavior tests for adguard_cli.

Drives the CLI via typer's CliRunner against a pytest-httpserver serving canned AdGuard Home
/control responses. `--server-url` avoids any `tofu` invocation. The client posts /control/login
first (cookie auth), so every fixture stubs it.
"""

import json

import adguard_cli as ag
from typer.testing import CliRunner

runner = CliRunner()


def _login(httpserver):
    httpserver.expect_request("/control/login", method="POST").respond_with_json({})


def _run(base, *args):
    return runner.invoke(ag.app, ["--server-url", base, *args])


def test_status_reports_running(httpserver):
    _login(httpserver)
    httpserver.expect_request("/control/status").respond_with_json(
        {"running": True, "version": "v0.107.52", "dns_addresses": ["10.0.0.5"]}
    )
    r = _run(httpserver.url_for(""), "--json", "status")
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)["running"] is True


def test_filters_lists_blocklists(httpserver):
    _login(httpserver)
    httpserver.expect_request("/control/filtering/status").respond_with_json(
        {"filters": [{"id": 1, "name": "AdGuard DNS filter", "enabled": True}]}
    )
    r = _run(httpserver.url_for(""), "--json", "filters")
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)[0]["name"] == "AdGuard DNS filter"


def test_check_passes_when_running_and_upstream_wired(httpserver):
    _login(httpserver)
    httpserver.expect_request("/control/status").respond_with_json(
        {"running": True, "version": "v0.107.52", "dns_addresses": ["10.0.0.5"]}
    )
    httpserver.expect_request("/control/dns_info").respond_with_json(
        {"upstream_dns": ["127.0.0.1:5335"], "protection_enabled": True}
    )
    r = _run(httpserver.url_for(""), "--json", "check")
    assert r.exit_code == 0, r.output
    doc = json.loads(r.output)
    assert doc["ok"] is True
    names = {c["name"]: c["status"] for c in doc["checks"]}
    assert names["running"] == "pass"
    assert names["unbound upstream wired"] == "pass"


def test_check_fails_when_upstream_not_unbound(httpserver):
    _login(httpserver)
    httpserver.expect_request("/control/status").respond_with_json(
        {"running": True, "version": "v0.107.52", "dns_addresses": ["10.0.0.5"]}
    )
    httpserver.expect_request("/control/dns_info").respond_with_json(
        {"upstream_dns": ["8.8.8.8"], "protection_enabled": True}
    )
    r = _run(httpserver.url_for(""), "--json", "check")
    assert r.exit_code == ag.dc.CHECK_FAIL_EXIT, r.output
    doc = json.loads(r.output)
    assert doc["ok"] is False


def test_check_fails_when_status_unreachable(httpserver):
    _login(httpserver)
    httpserver.expect_request("/control/status").respond_with_data("nope", status=500)
    r = _run(httpserver.url_for(""), "--json", "check")
    assert r.exit_code == ag.dc.CHECK_FAIL_EXIT, r.output
