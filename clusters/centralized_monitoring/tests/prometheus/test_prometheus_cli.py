"""Hermetic behavior tests for prometheus_cli (TDD).

Drives the CLI via typer's CliRunner against a pytest-httpserver serving canned
Prometheus HTTP API responses. `--server-url` avoids any `tofu` invocation.
"""

import json

import prometheus_cli as pc
from typer.testing import CliRunner

runner = CliRunner()


def _vector(*series):
    return {"status": "success", "data": {"resultType": "vector", "result": list(series)}}


def _up(job, instance="x:9090", val="1"):
    return {
        "metric": {"__name__": "up", "job": job, "instance": instance},
        "value": [1700000000, val],
    }


def _target(job, health="up", instance="x:9100"):
    return {
        "scrapePool": job,
        "labels": {"job": job, "instance": instance},
        "health": health,
        "lastError": "" if health == "up" else "connection refused",
    }


def _targets_payload(targets):
    return {"status": "success", "data": {"activeTargets": targets, "droppedTargets": []}}


def _server(httpserver, *, targets=None, up_series=1):
    httpserver.expect_request("/api/v1/query").respond_with_json(
        _vector(*[_up("prometheus") for _ in range(up_series)])
    )
    if targets is None:
        targets = [_target("prometheus"), _target("node")]
    httpserver.expect_request("/api/v1/targets").respond_with_json(
        _targets_payload(targets)
    )
    return httpserver.url_for("")


def _run(base, *args):
    return runner.invoke(pc.app, ["--server-url", base, *args])


# ------------------------------------------------------------------ introspection


def test_query_returns_result_series(httpserver):
    base = _server(httpserver, up_series=2)
    r = _run(base, "--json", "query", "up")
    assert r.exit_code == 0, r.output
    result = json.loads(r.output)
    assert len(result) == 2
    assert result[0]["metric"]["__name__"] == "up"


def test_targets_lists_health(httpserver):
    base = _server(httpserver, targets=[_target("prometheus"), _target("node", health="down")])
    r = _run(base, "--json", "targets")
    assert r.exit_code == 0, r.output
    rows = {row["job"]: row["health"] for row in json.loads(r.output)}
    assert rows == {"prometheus": "up", "node": "down"}


def test_label_values(httpserver):
    base = _server(httpserver)
    httpserver.expect_request("/api/v1/label/job/values").respond_with_json(
        {"status": "success", "data": ["prometheus", "node"]}
    )
    r = _run(base, "--json", "label-values", "job")
    assert r.exit_code == 0, r.output
    assert json.loads(r.output) == ["prometheus", "node"]


def test_alerts(httpserver):
    base = _server(httpserver)
    httpserver.expect_request("/api/v1/alerts").respond_with_json(
        {"status": "success", "data": {"alerts": [{"labels": {"alertname": "TargetDown"}, "state": "firing"}]}}
    )
    r = _run(base, "--json", "alerts")
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)[0]["state"] == "firing"


def test_rules(httpserver):
    base = _server(httpserver)
    httpserver.expect_request("/api/v1/rules").respond_with_json(
        {"status": "success", "data": {"groups": [{"name": "g1", "rules": []}]}}
    )
    r = _run(base, "--json", "rules")
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)[0]["name"] == "g1"


# -------------------------------------------------------------------------- check


def test_check_passes_when_all_targets_up(httpserver):
    base = _server(httpserver)
    r = _run(base, "--json", "check")
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)["ok"] is True


def test_check_fails_on_down_target(httpserver):
    base = _server(httpserver, targets=[_target("prometheus"), _target("node", health="down")])
    r = _run(base, "--json", "check")
    assert r.exit_code == 2
    checks = json.loads(r.output)["checks"]
    assert any(c["name"] == "no down targets" and c["status"] == "fail" for c in checks)


def test_check_skips_expected_jobs_in_server_url_mode(httpserver):
    base = _server(httpserver)
    r = _run(base, "--json", "check")
    checks = json.loads(r.output)["checks"]
    assert any(c["name"] == "expected jobs" and c["status"] == "skip" for c in checks)


def test_check_fails_on_connection_refused():
    r = runner.invoke(pc.app, ["--server-url", "http://127.0.0.1:1", "--json", "check"])
    assert r.exit_code == 2
