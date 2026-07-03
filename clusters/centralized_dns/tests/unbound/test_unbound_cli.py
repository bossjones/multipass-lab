"""Hermetic behavior tests for unbound_cli.

Drives the CLI via typer's CliRunner against a pytest-httpserver serving a canned
unbound_exporter /metrics body. `--server-url` avoids any `tofu` invocation.
"""

import json

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
