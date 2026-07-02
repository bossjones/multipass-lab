"""Hermetic behavior tests for stepca_cli (TDD).

Every test drives the CLI via typer's CliRunner against a throwaway in-process HTTP server
(pytest-httpserver) serving canned step-ca API responses. No VM, no Docker. `--server-url`
points the CLI at the fake server, so `tofu` is never invoked.
"""

import json

import stepca_cli as sc
from typer.testing import CliRunner

runner = CliRunner()

FAKE_ROOT_PEM = "-----BEGIN CERTIFICATE-----\nMIIfake\n-----END CERTIFICATE-----\n"


def _healthy(httpserver, *, status="ok", provisioners=None, root=FAKE_ROOT_PEM):
    httpserver.expect_request("/health").respond_with_json({"status": status})
    provs = (
        provisioners
        if provisioners is not None
        else [{"type": "ACME", "name": "acme"}, {"type": "JWK", "name": "admin"}]
    )
    httpserver.expect_request("/provisioners").respond_with_json({"provisioners": provs})
    httpserver.expect_request("/roots.pem").respond_with_data(
        root, content_type="application/x-pem-file"
    )
    return httpserver.url_for("")


def _run(base, *args):
    # Global options live on the app callback, so they precede the subcommand.
    return runner.invoke(sc.app, ["--server-url", base, *args])


# ---- check ----


def test_check_passes_when_all_healthy(httpserver):
    base = _healthy(httpserver)
    r = _run(base, "--json", "check")
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)["ok"] is True


def test_check_fails_when_health_not_ok(httpserver):
    base = _healthy(httpserver, status="degraded")
    r = _run(base, "--json", "check")
    assert r.exit_code == 2
    checks = {c["name"]: c["status"] for c in json.loads(r.output)["checks"]}
    assert checks["ca health"] == "fail"


def test_check_fails_when_no_acme_provisioner(httpserver):
    base = _healthy(httpserver, provisioners=[{"type": "JWK", "name": "admin"}])
    r = _run(base, "--json", "check")
    assert r.exit_code == 2
    checks = {c["name"]: c["status"] for c in json.loads(r.output)["checks"]}
    assert checks["acme provisioner"] == "fail"


def test_check_fails_when_no_root_served(httpserver):
    base = _healthy(httpserver, root="")
    r = _run(base, "--json", "check")
    assert r.exit_code == 2
    checks = {c["name"]: c["status"] for c in json.loads(r.output)["checks"]}
    assert checks["root cert served"] == "fail"


def test_check_fails_on_connection_refused():
    # Nothing listening on this port -> transport error -> exit 2.
    r = _run("http://127.0.0.1:1", "--json", "check")
    assert r.exit_code == 2
    assert json.loads(r.output)["ok"] is False


# ---- introspection ----


def test_provisioners_json_lists_name_and_type(httpserver):
    base = _healthy(httpserver)
    r = _run(base, "--json", "provisioners")
    assert r.exit_code == 0, r.output
    data = json.loads(r.output)
    names = {p["name"] for p in data}
    assert "acme" in names


def test_roots_json_counts_certs(httpserver):
    base = _healthy(httpserver)
    r = _run(base, "--json", "roots")
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)["count"] == 1


def test_health_json_reports_status(httpserver):
    base = _healthy(httpserver)
    r = _run(base, "--json", "health")
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)["status"] == "ok"
