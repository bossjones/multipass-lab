"""Hermetic behavior tests for tls_cli (TDD).

Drives the CLI via CliRunner against a real in-process TLS server (see conftest.py) serving a
leaf either signed by a step-ca-analogue root or issued by a STAGING-named issuer. `--internal`
/ `--staging` override the mode so `tofu` is never invoked.
"""

import json

import tls_cli as tc
from typer.testing import CliRunner

runner = CliRunner()


def _run(*args):
    return runner.invoke(tc.app, list(args))


# ---- inspect ----


def test_inspect_reports_issuer_subject_and_sans(internal_server):
    r = _run("--json", "inspect", "127.0.0.1", "--port", str(internal_server))
    assert r.exit_code == 0, r.output
    data = json.loads(r.output)
    assert data["subject_cn"] == "warden.lab.test"
    assert "centralized-pki-ca Root CA" in data["issuer_cn"]
    assert "warden.lab.test" in data["sans"]


# ---- check: internal (chain to step-ca root) ----


def test_check_internal_passes_with_correct_root(internal_server, root_pem):
    root_path, _key, _cert = root_pem
    r = _run(
        "--json", "check", "127.0.0.1",
        "--port", str(internal_server), "--internal", "--ca-cert", root_path,
    )
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)["ok"] is True


def test_check_internal_fails_with_wrong_root(internal_server, wrong_root_pem):
    r = _run(
        "--json", "check", "127.0.0.1",
        "--port", str(internal_server), "--internal", "--ca-cert", wrong_root_pem,
    )
    assert r.exit_code == 2
    checks = {c["name"]: c["status"] for c in json.loads(r.output)["checks"]}
    assert checks["chains to step-ca root"] == "fail"


def test_check_internal_fails_without_root(internal_server):
    # No --ca-cert and no tofu -> no root available -> fail.
    r = _run(
        "--json", "check", "127.0.0.1",
        "--port", str(internal_server), "--internal",
    )
    assert r.exit_code == 2


# ---- check: staging (issuer is LE staging) ----


def test_check_staging_passes_on_staging_issuer(staging_server):
    r = _run(
        "--json", "check", "127.0.0.1",
        "--port", str(staging_server), "--staging",
    )
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)["ok"] is True


def test_check_staging_fails_on_nonstaging_issuer(internal_server):
    # internal server's issuer is the step-ca root, not a STAGING issuer.
    r = _run(
        "--json", "check", "127.0.0.1",
        "--port", str(internal_server), "--staging",
    )
    assert r.exit_code == 2
    checks = {c["name"]: c["status"] for c in json.loads(r.output)["checks"]}
    assert checks["issuer is LE staging"] == "fail"
