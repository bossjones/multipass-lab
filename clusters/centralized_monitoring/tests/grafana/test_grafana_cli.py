"""Hermetic behavior tests for grafana_cli (TDD).

Every test drives the CLI via typer's CliRunner against a throwaway in-process HTTP
server (pytest-httpserver) serving canned Grafana API responses. No VM, no Docker.
`--server-url` points the CLI at the fake server, so `tofu` is never invoked.
"""

import json

import grafana_cli as gc
from typer.testing import CliRunner

runner = CliRunner()


def _healthy(
    httpserver,
    *,
    with_openobserve=True,
    dashboards=2,
    ds_status="OK",
    oo_status="OK",
    db="ok",
):
    httpserver.expect_request("/api/health").respond_with_json(
        {"database": db, "version": "11.0.0"}
    )
    ds = [
        {
            "name": "Prometheus",
            "type": "prometheus",
            "uid": "prometheus",
            "url": "http://prometheus:9090",
        }
    ]
    if with_openobserve:
        ds.append(
            {
                "name": "OpenObserve",
                "type": "prometheus",
                "uid": "openobserve",
                "url": "http://openobserve:5080/api/default/prometheus",
            }
        )
    httpserver.expect_request("/api/datasources").respond_with_json(ds)
    httpserver.expect_request(
        "/api/datasources/uid/prometheus/health"
    ).respond_with_json({"status": ds_status, "message": "ok"})
    httpserver.expect_request(
        "/api/datasources/uid/openobserve/health"
    ).respond_with_json({"status": oo_status, "message": "ok"})
    dl = [
        {"uid": f"d{i}", "title": f"Dash {i}", "folderTitle": "General"}
        for i in range(dashboards)
    ]
    httpserver.expect_request("/api/search").respond_with_json(dl)
    return httpserver.url_for("")


def _run(base, *args):
    # Global options live on the app callback, so they precede the subcommand.
    return runner.invoke(gc.app, ["--server-url", base, *args])


# ------------------------------------------------------------------ introspection


def test_health_json_reports_database_ok(httpserver):
    base = _healthy(httpserver)
    r = _run(base, "--json", "health")
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)["database"] == "ok"


def test_datasources_lists_both_names(httpserver):
    base = _healthy(httpserver)
    r = _run(base, "--json", "datasources")
    assert r.exit_code == 0, r.output
    names = {d["name"] for d in json.loads(r.output)}
    assert {"Prometheus", "OpenObserve"} <= names


def test_datasource_health_by_name(httpserver):
    base = _healthy(httpserver)
    r = _run(base, "--json", "datasource-health", "Prometheus")
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)["status"] == "OK"


def test_dashboards_lists_uids(httpserver):
    base = _healthy(httpserver)
    r = _run(base, "--json", "dashboards")
    assert r.exit_code == 0, r.output
    assert {d["uid"] for d in json.loads(r.output)} == {"d0", "d1"}


# -------------------------------------------------------------------------- check


def test_check_passes_when_all_healthy(httpserver):
    base = _healthy(httpserver)
    r = _run(base, "--json", "check")
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)["ok"] is True


def test_check_fails_on_unhealthy_prometheus_datasource(httpserver):
    base = _healthy(httpserver, ds_status="ERROR")
    r = _run(base, "--json", "check")
    assert r.exit_code == 2
    checks = json.loads(r.output)["checks"]
    assert any(
        c["name"] == "prometheus datasource" and c["status"] == "fail" for c in checks
    )


def test_check_fails_when_grafana_database_not_ok(httpserver):
    base = _healthy(httpserver, db="failing")
    r = _run(base, "--json", "check")
    assert r.exit_code == 2


def test_check_fails_when_no_dashboards(httpserver):
    base = _healthy(httpserver, dashboards=0)
    r = _run(base, "--json", "check")
    assert r.exit_code == 2


def test_check_skips_openobserve_when_absent(httpserver):
    base = _healthy(httpserver, with_openobserve=False)
    r = _run(base, "--json", "check")
    assert r.exit_code == 0, r.output
    checks = json.loads(r.output)["checks"]
    assert any(
        c["name"] == "openobserve datasource" and c["status"] == "skip" for c in checks
    )


def test_check_fails_on_connection_refused():
    r = runner.invoke(
        gc.app, ["--server-url", "http://127.0.0.1:1", "--json", "check"]
    )
    assert r.exit_code == 2
