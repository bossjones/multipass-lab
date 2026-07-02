"""Hermetic behavior tests for vaultwarden_cli (TDD).

CliRunner + pytest-httpserver serving canned Vaultwarden responses. `--server-url` points the CLI
at the fake server (domain empty -> no Host header), so `tofu` is never invoked.
"""

import json

import vaultwarden_cli as vc
from typer.testing import CliRunner

runner = CliRunner()


def _healthy(httpserver, *, alive_status=200, version_status=200):
    # /alive returns a bare RFC3339 timestamp string (not JSON).
    httpserver.expect_request("/alive").respond_with_data(
        "2026-07-02T00:00:00.000000000Z", status=alive_status
    )
    httpserver.expect_request("/api/version").respond_with_json(
        "1.32.0", status=version_status
    )
    return httpserver.url_for("")


def _run(base, *args):
    return runner.invoke(vc.app, ["--server-url", base, *args])


def test_check_passes_when_alive(httpserver):
    base = _healthy(httpserver)
    r = _run(base, "--json", "check")
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)["ok"] is True


def test_check_fails_when_not_alive(httpserver):
    base = _healthy(httpserver, alive_status=503)
    r = _run(base, "--json", "check")
    assert r.exit_code == 2
    checks = {c["name"]: c["status"] for c in json.loads(r.output)["checks"]}
    assert checks["vaultwarden alive"] == "fail"


def test_check_skips_version_on_404_but_still_passes(httpserver):
    base = _healthy(httpserver, version_status=404)
    r = _run(base, "--json", "check")
    assert r.exit_code == 0, r.output
    checks = {c["name"]: c["status"] for c in json.loads(r.output)["checks"]}
    assert checks["vaultwarden alive"] == "pass"
    assert checks["version"] == "skip"


def test_check_fails_on_connection_refused():
    r = _run("http://127.0.0.1:1", "--json", "check")
    assert r.exit_code == 2
    assert json.loads(r.output)["ok"] is False


def test_alive_json_returns_timestamp_text(httpserver):
    base = _healthy(httpserver)
    r = _run(base, "--json", "alive")
    assert r.exit_code == 0, r.output
    data = json.loads(r.output)
    assert "2026-07-02" in data["text"]
