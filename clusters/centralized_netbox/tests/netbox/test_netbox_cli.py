"""Hermetic behavior tests for netbox_cli (TDD).

Every test drives the CLI via typer's CliRunner against a throwaway in-process HTTP server
(pytest-httpserver) serving canned NetBox API responses. No VM, no Docker. `--server-url` +
`--token` point the CLI at the fake server, so `tofu` is never invoked. The default cluster/VM
names (centralized-netbox / centralized-netbox-client) are what the canned payloads use.
"""

import json

import netbox_cli as nc
from typer.testing import CliRunner

runner = CliRunner()

CLUSTER_NAME = "centralized-netbox"
VM_NAME = "centralized-netbox-client"


def _paginated(results):
    return {"count": len(results), "next": None, "previous": None, "results": results}


def _cluster(id_=1):
    return {"id": id_, "url": "", "name": CLUSTER_NAME, "type": {"id": 1, "name": "Multipass"}}


def _vm(*, primary_ip=True, status="active", name=VM_NAME, id_=1):
    return {
        "id": id_,
        "url": "",
        "name": name,
        "status": {"value": status, "label": status.capitalize()},
        "cluster": {"id": 1, "name": CLUSTER_NAME},
        "primary_ip4": {"id": 7, "address": "10.10.10.5/24"} if primary_ip else None,
    }


def _healthy(
    httpserver,
    *,
    status_code=200,
    clusters=None,
    vms=None,
    clusters_status=200,
):
    httpserver.expect_request("/api/status/").respond_with_json(
        {"netbox-version": "4.2.0", "django-version": "5.1", "rq-workers-running": 1},
        status=status_code,
    )
    # pynetbox may probe the API root; answer harmlessly.
    httpserver.expect_request("/api/").respond_with_json({})
    if clusters_status >= 400:
        httpserver.expect_request("/api/virtualization/clusters/").respond_with_data(
            "forbidden", status=clusters_status
        )
    else:
        httpserver.expect_request("/api/virtualization/clusters/").respond_with_json(
            _paginated(clusters if clusters is not None else [_cluster()])
        )
    httpserver.expect_request("/api/virtualization/virtual-machines/").respond_with_json(
        _paginated(vms if vms is not None else [_vm()])
    )
    return httpserver.url_for("")


def _run(base, *args, token="0123456789abcdef0123456789abcdef01234567"):
    # Global options live on the app callback, so they precede the subcommand.
    return runner.invoke(nc.app, ["--server-url", base, "--token", token, *args])


# --- check: happy path -------------------------------------------------------


def test_check_passes_when_all_healthy(httpserver):
    base = _healthy(httpserver)
    r = _run(base, "--json", "check")
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)["ok"] is True


# --- check: failure paths ----------------------------------------------------


def test_check_fails_when_netbox_unreachable(httpserver):
    base = _healthy(httpserver, status_code=503)
    r = _run(base, "--json", "check")
    assert r.exit_code == 2
    checks = json.loads(r.output)["checks"]
    assert any(c["name"] == "netbox reachable" and c["status"] == "fail" for c in checks)


def test_check_fails_on_bad_token(httpserver):
    base = _healthy(httpserver, clusters_status=403)
    r = _run(base, "--json", "check")
    assert r.exit_code == 2
    checks = json.loads(r.output)["checks"]
    assert any(c["name"] == "token authenticates" and c["status"] == "fail" for c in checks)


def test_check_fails_when_cluster_missing(httpserver):
    base = _healthy(httpserver, clusters=[])
    r = _run(base, "--json", "check")
    assert r.exit_code == 2
    checks = json.loads(r.output)["checks"]
    assert any(c["name"] == "cluster present" and c["status"] == "fail" for c in checks)


def test_check_fails_when_vm_missing(httpserver):
    base = _healthy(httpserver, vms=[])
    r = _run(base, "--json", "check")
    assert r.exit_code == 2
    checks = json.loads(r.output)["checks"]
    assert any(c["name"] == "client vm registered" and c["status"] == "fail" for c in checks)


def test_check_fails_when_vm_has_no_primary_ip(httpserver):
    base = _healthy(httpserver, vms=[_vm(primary_ip=False)])
    r = _run(base, "--json", "check")
    assert r.exit_code == 2
    checks = json.loads(r.output)["checks"]
    assert any(c["name"] == "primary ip assigned" and c["status"] == "fail" for c in checks)


# --- introspection -----------------------------------------------------------


def test_status_reports_version(httpserver):
    base = _healthy(httpserver)
    r = _run(base, "--json", "status")
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)["netbox-version"] == "4.2.0"


def test_vms_lists_registered_vm(httpserver):
    base = _healthy(httpserver)
    r = _run(base, "--json", "vms")
    assert r.exit_code == 0, r.output
    rows = json.loads(r.output)
    assert any(row["name"] == VM_NAME for row in rows)
