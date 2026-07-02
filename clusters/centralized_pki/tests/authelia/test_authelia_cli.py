"""Hermetic behavior tests for authelia_cli (TDD).

CliRunner + pytest-httpserver serving canned Authelia responses. `--server-url` points the CLI
at the fake server (domain empty -> no Host header), so `tofu` is never invoked.
"""

import json

import authelia_cli as ac
from typer.testing import CliRunner

runner = CliRunner()


def _healthy(httpserver, *, health_status=200, forward_status=401):
    httpserver.expect_request("/api/health").respond_with_json(
        {"status": "OK"}, status=health_status
    )
    httpserver.expect_request("/api/authz/forward-auth").respond_with_data(
        "unauthorized", status=forward_status
    )
    return httpserver.url_for("")


def _run(base, *args):
    return runner.invoke(ac.app, ["--server-url", base, *args])


def test_check_passes_when_healthy_and_enforcing(httpserver):
    base = _healthy(httpserver)
    r = _run(base, "--json", "check")
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)["ok"] is True


def test_check_fails_when_health_5xx(httpserver):
    base = _healthy(httpserver, health_status=500)
    r = _run(base, "--json", "check")
    assert r.exit_code == 2
    checks = {c["name"]: c["status"] for c in json.loads(r.output)["checks"]}
    assert checks["authelia health"] == "fail"


def test_check_fails_when_forward_auth_404(httpserver):
    # 404 -> forward-auth not configured/enforcing.
    base = _healthy(httpserver, forward_status=404)
    r = _run(base, "--json", "check")
    assert r.exit_code == 2
    checks = {c["name"]: c["status"] for c in json.loads(r.output)["checks"]}
    assert checks["forward-auth enforcing"] == "fail"


def test_check_fails_on_connection_refused():
    r = _run("http://127.0.0.1:1", "--json", "check")
    assert r.exit_code == 2
    assert json.loads(r.output)["ok"] is False


def test_health_json_reports_status(httpserver):
    base = _healthy(httpserver)
    r = _run(base, "--json", "health")
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)["status"] == "OK"
