"""Hermetic behavior tests for openobserve_cli (TDD).

Drives the CLI via typer's CliRunner against a pytest-httpserver serving canned
OpenObserve REST responses. `--server-url` avoids any `tofu` invocation.
"""

import base64
import json

import openobserve_cli as oo
from typer.testing import CliRunner

runner = CliRunner()

DEFAULT_AUTH = (
    "Basic " + base64.b64encode(b"admin@example.com:Complexpass#123").decode()
)


def _server(httpserver, *, streams=None):
    httpserver.expect_request("/healthz").respond_with_json({"status": "ok"})
    st = (
        streams if streams is not None else [{"name": "default", "stream_type": "logs"}]
    )
    httpserver.expect_request("/api/default/streams").respond_with_json({"list": st})
    return httpserver.url_for("")


def _run(base, *args):
    return runner.invoke(oo.app, ["--server-url", base, *args])


# ------------------------------------------------------------------ introspection


def test_health_reports_status(httpserver):
    base = _server(httpserver)
    r = _run(base, "--json", "health")
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)["status"] == "ok"


def test_streams_lists_names(httpserver):
    base = _server(httpserver, streams=[{"name": "traces", "stream_type": "traces"}])
    r = _run(base, "--json", "streams")
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)[0]["name"] == "traces"


def test_streams_sends_basic_auth(httpserver):
    httpserver.expect_request("/healthz").respond_with_json({"status": "ok"})
    httpserver.expect_request(
        "/api/default/streams", headers={"Authorization": DEFAULT_AUTH}
    ).respond_with_json({"list": [{"name": "default", "stream_type": "logs"}]})
    r = _run(httpserver.url_for(""), "--json", "streams")
    assert r.exit_code == 0, r.output


def test_search_returns_hits(httpserver):
    base = _server(httpserver)
    httpserver.expect_request("/api/default/_search", method="POST").respond_with_json(
        {"hits": [{"_timestamp": 1, "log": "hello"}], "total": 1}
    )
    r = _run(base, "--json", "search", "SELECT * FROM default")
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)[0]["log"] == "hello"


def test_query_promql(httpserver):
    base = _server(httpserver)
    httpserver.expect_request("/api/default/prometheus/api/v1/query").respond_with_json(
        {
            "status": "success",
            "data": {
                "resultType": "vector",
                "result": [{"metric": {}, "value": [1, "1"]}],
            },
        }
    )
    r = _run(base, "--json", "query", "up")
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)["data"]["result"][0]["value"][1] == "1"


# -------------------------------------------------------------------------- check


def test_check_passes_when_healthy_and_authed(httpserver):
    base = _server(httpserver)
    r = _run(base, "--json", "check")
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)["ok"] is True


def test_check_fails_on_auth_401(httpserver):
    httpserver.expect_request("/healthz").respond_with_json({"status": "ok"})
    httpserver.expect_request("/api/default/streams").respond_with_data(
        "unauthorized", status=401
    )
    r = _run(httpserver.url_for(""), "--json", "check")
    assert r.exit_code == 2
    checks = json.loads(r.output)["checks"]
    assert any(c["name"] == "auth" and c["status"] == "fail" for c in checks)


def test_check_streams_present_is_skip_by_default_when_empty(httpserver):
    base = _server(httpserver, streams=[])
    r = _run(base, "--json", "check")
    assert r.exit_code == 0, r.output


def test_check_require_streams_fails_when_empty(httpserver):
    base = _server(httpserver, streams=[])
    r = _run(base, "--json", "check", "--require-streams")
    assert r.exit_code == 2
    checks = json.loads(r.output)["checks"]
    assert any(c["name"] == "streams present" and c["status"] == "fail" for c in checks)


def test_check_fails_on_connection_refused():
    r = runner.invoke(oo.app, ["--server-url", "http://127.0.0.1:1", "--json", "check"])
    assert r.exit_code == 2


# ---------------------------------------------------- check --require-metrics/logs


def test_check_require_metrics_passes_when_up_returns_series(httpserver):
    base = _server(httpserver)
    httpserver.expect_request("/api/default/prometheus/api/v1/query").respond_with_json(
        {
            "status": "success",
            "data": {
                "resultType": "vector",
                "result": [{"metric": {"__name__": "up"}, "value": [1, "1"]}],
            },
        }
    )
    r = _run(base, "--json", "check", "--require-metrics")
    assert r.exit_code == 0, r.output
    checks = json.loads(r.output)["checks"]
    assert any(c["name"] == "metrics present" and c["status"] == "pass" for c in checks)


def test_check_require_metrics_fails_when_no_series(httpserver):
    base = _server(httpserver)
    httpserver.expect_request("/api/default/prometheus/api/v1/query").respond_with_json(
        {"status": "success", "data": {"resultType": "vector", "result": []}}
    )
    r = _run(base, "--json", "check", "--require-metrics")
    assert r.exit_code == 2
    checks = json.loads(r.output)["checks"]
    assert any(c["name"] == "metrics present" and c["status"] == "fail" for c in checks)


def test_check_require_logs_passes_when_stream_has_rows(httpserver):
    base = _server(
        httpserver, streams=[{"name": "container_logs", "stream_type": "logs"}]
    )
    httpserver.expect_request("/api/default/_search", method="POST").respond_with_json(
        {"hits": [{"_timestamp": 1, "body": "hello"}], "total": 1}
    )
    r = _run(base, "--json", "check", "--require-logs")
    assert r.exit_code == 0, r.output
    checks = json.loads(r.output)["checks"]
    assert any(c["name"] == "logs present" and c["status"] == "pass" for c in checks)


def test_check_require_logs_fails_when_no_logs_streams(httpserver):
    base = _server(httpserver, streams=[{"name": "up", "stream_type": "metrics"}])
    r = _run(base, "--json", "check", "--require-logs")
    assert r.exit_code == 2
    checks = json.loads(r.output)["checks"]
    assert any(c["name"] == "logs present" and c["status"] == "fail" for c in checks)
