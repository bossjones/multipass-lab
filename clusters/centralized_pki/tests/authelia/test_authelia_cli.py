"""Hermetic behavior tests for authelia_cli (TDD).

CliRunner + pytest-httpserver serving canned Authelia responses. `--server-url` points the CLI
at the fake server (domain empty -> no Host header), so `tofu` is never invoked.
"""

import json

import authelia_cli as ac
from typer.testing import CliRunner

runner = CliRunner()


def _healthy(
    httpserver,
    *,
    health_status=200,
    admin_status=302,
    admin_location="https://auth.example.com/?rd=https%3A%2F%2Fvault.example.com%2Fadmin",
):
    httpserver.expect_request("/api/health").respond_with_json(
        {"status": "OK"}, status=health_status
    )
    headers = {"Location": admin_location} if admin_location else {}
    httpserver.expect_request("/admin").respond_with_data(
        "", status=admin_status, headers=headers
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


def test_check_fails_when_protected_route_not_enforced(httpserver):
    # 200 with no portal redirect -> the protected route isn't gated by forward-auth.
    base = _healthy(httpserver, admin_status=200, admin_location=None)
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
