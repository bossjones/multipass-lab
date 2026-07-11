"""Hermetic behavior tests for adguard_cli.

Drives the CLI via typer's CliRunner against a pytest-httpserver serving canned AdGuard Home
/control responses. `--server-url` avoids any `tofu` invocation. The client posts /control/login
first (cookie auth), so every fixture stubs it.
"""

import json
import subprocess

import adguard_cli as ag
from typer.testing import CliRunner

runner = CliRunner()


def _login(httpserver):
    httpserver.expect_request("/control/login", method="POST").respond_with_json({})


def _run(base, *args):
    return runner.invoke(ag.app, ["--server-url", base, *args])


class _FakeCompleted:
    def __init__(self, stdout="", stderr="", returncode=0):
        self.stdout = stdout
        self.stderr = stderr
        self.returncode = returncode


def _fake_subprocess_run(
    tofu_json=None, dig_stdout="93.184.216.34\n", ssh_result=(0, "active\n", "")
):
    """A `subprocess.run` stand-in dispatching on argv[0] — covers `tofu`, `dig`, and `ssh`,
    the three external commands adguard_cli's HA surface shells out to."""

    def _run(cmd, **kwargs):
        if cmd[0] == "tofu":
            return _FakeCompleted(stdout=json.dumps(tofu_json or {}))
        if cmd[0] == "dig":
            return _FakeCompleted(stdout=dig_stdout)
        if cmd[0] == "ssh":
            rc, out, err = ssh_result
            return _FakeCompleted(stdout=out, stderr=err, returncode=rc)
        raise AssertionError(f"unexpected subprocess.run call: {cmd}")

    return _run


def _ha_tofu_doc(host, port=None):
    """A fake `tofu output -json` doc for enable_ha=true: both roles resolve to `host`."""
    return {
        "hosts": {
            "value": {
                "primary": {"name": "p", "ipv4": host},
                "secondary": {"name": "s", "ipv4": host},
            }
        },
        "enabled_features": {"value": {"ha": True}},
        "dns_endpoint": {"value": "10.10.10.99"},
        "dns_rewrite_target": {"value": host},
    }


def test_status_reports_running(httpserver):
    _login(httpserver)
    httpserver.expect_request("/control/status").respond_with_json(
        {"running": True, "version": "v0.107.52", "dns_addresses": ["10.0.0.5"]}
    )
    r = _run(httpserver.url_for(""), "--json", "status")
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)["running"] is True


def test_filters_lists_blocklists(httpserver):
    _login(httpserver)
    httpserver.expect_request("/control/filtering/status").respond_with_json(
        {"filters": [{"id": 1, "name": "AdGuard DNS filter", "enabled": True}]}
    )
    r = _run(httpserver.url_for(""), "--json", "filters")
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)[0]["name"] == "AdGuard DNS filter"


def test_check_passes_when_running_and_upstream_wired(httpserver):
    _login(httpserver)
    httpserver.expect_request("/control/status").respond_with_json(
        {"running": True, "version": "v0.107.52", "dns_addresses": ["10.0.0.5"]}
    )
    httpserver.expect_request("/control/dns_info").respond_with_json(
        {"upstream_dns": ["127.0.0.1:5335"], "protection_enabled": True}
    )
    r = _run(httpserver.url_for(""), "--json", "check")
    assert r.exit_code == 0, r.output
    doc = json.loads(r.output)
    assert doc["ok"] is True
    names = {c["name"]: c["status"] for c in doc["checks"]}
    assert names["running"] == "pass"
    assert names["unbound upstream wired"] == "pass"


def test_check_fails_when_upstream_not_unbound(httpserver):
    _login(httpserver)
    httpserver.expect_request("/control/status").respond_with_json(
        {"running": True, "version": "v0.107.52", "dns_addresses": ["10.0.0.5"]}
    )
    httpserver.expect_request("/control/dns_info").respond_with_json(
        {"upstream_dns": ["8.8.8.8"], "protection_enabled": True}
    )
    r = _run(httpserver.url_for(""), "--json", "check")
    assert r.exit_code == ag.dc.CHECK_FAIL_EXIT, r.output
    doc = json.loads(r.output)
    assert doc["ok"] is False


def test_check_fails_when_status_unreachable(httpserver):
    _login(httpserver)
    httpserver.expect_request("/control/status").respond_with_data("nope", status=500)
    r = _run(httpserver.url_for(""), "--json", "check")
    assert r.exit_code == ag.dc.CHECK_FAIL_EXIT, r.output


# --- DNS rewrites ------------------------------------------------------------


def _posts_to(httpserver, path):
    """Bodies of every POST the CLI made to `path`, in order (from the request log)."""
    return [
        req.get_json()
        for req, _resp in httpserver.log
        if req.path == path and req.method == "POST"
    ]


def test_rewrite_list(httpserver):
    _login(httpserver)
    httpserver.expect_request("/control/rewrite/list").respond_with_json(
        [{"domain": "grafana.lab.example.com", "answer": "10.0.0.5"}]
    )
    r = _run(httpserver.url_for(""), "--json", "rewrite-list")
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)[0]["domain"] == "grafana.lab.example.com"


def test_rewrite_set_adds_when_absent(httpserver):
    _login(httpserver)
    httpserver.expect_request("/control/rewrite/list").respond_with_json([])
    httpserver.expect_request("/control/rewrite/add", method="POST").respond_with_json(
        {}
    )
    r = _run(
        httpserver.url_for(""),
        "--json",
        "rewrite-set",
        "netbox.lab.example.com",
        "10.0.0.9",
    )
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)["status"] == "added"
    assert _posts_to(httpserver, "/control/rewrite/add") == [
        {"domain": "netbox.lab.example.com", "answer": "10.0.0.9"}
    ]
    assert _posts_to(httpserver, "/control/rewrite/delete") == []


def test_rewrite_set_deletes_then_adds_when_row_exists(httpserver):
    _login(httpserver)
    httpserver.expect_request("/control/rewrite/list").respond_with_json(
        [{"domain": "netbox.lab.example.com", "answer": "10.0.0.1"}]
    )
    httpserver.expect_request(
        "/control/rewrite/delete", method="POST"
    ).respond_with_json({})
    httpserver.expect_request("/control/rewrite/add", method="POST").respond_with_json(
        {}
    )
    r = _run(
        httpserver.url_for(""),
        "--json",
        "rewrite-set",
        "netbox.lab.example.com",
        "10.0.0.9",
    )
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)["status"] == "updated"
    # Deletes the stale row (old IP) before adding the new one.
    assert _posts_to(httpserver, "/control/rewrite/delete") == [
        {"domain": "netbox.lab.example.com", "answer": "10.0.0.1"}
    ]
    assert _posts_to(httpserver, "/control/rewrite/add") == [
        {"domain": "netbox.lab.example.com", "answer": "10.0.0.9"}
    ]


def test_rewrite_set_unchanged_when_already_correct(httpserver):
    _login(httpserver)
    httpserver.expect_request("/control/rewrite/list").respond_with_json(
        [{"domain": "netbox.lab.example.com", "answer": "10.0.0.9"}]
    )
    r = _run(
        httpserver.url_for(""),
        "--json",
        "rewrite-set",
        "netbox.lab.example.com",
        "10.0.0.9",
    )
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)["status"] == "unchanged"
    assert _posts_to(httpserver, "/control/rewrite/add") == []
    assert _posts_to(httpserver, "/control/rewrite/delete") == []


def test_rewrite_sync_batch_from_stdin(httpserver):
    _login(httpserver)
    # One new host, one host that needs its IP updated.
    httpserver.expect_request("/control/rewrite/list").respond_with_json(
        [{"domain": "grafana.lab.example.com", "answer": "10.0.0.1"}]
    )
    httpserver.expect_request("/control/rewrite/add", method="POST").respond_with_json(
        {}
    )
    httpserver.expect_request(
        "/control/rewrite/delete", method="POST"
    ).respond_with_json({})
    payload = json.dumps(
        {
            "grafana.lab.example.com": "10.0.0.5",  # changed -> updated
            "netbox.lab.example.com": "10.0.0.9",  # new -> added
        }
    )
    r = runner.invoke(
        ag.app,
        [
            "--server-url",
            httpserver.url_for(""),
            "--json",
            "rewrite-sync",
            "--file",
            "-",
        ],
        input=payload,
    )
    assert r.exit_code == 0, r.output
    doc = json.loads(r.output)
    assert set(doc["added"]) == {"netbox.lab.example.com"}
    assert set(doc["updated"]) == {"grafana.lab.example.com"}
    # grafana's stale row deleted, both new answers added.
    assert {"domain": "grafana.lab.example.com", "answer": "10.0.0.1"} in _posts_to(
        httpserver, "/control/rewrite/delete"
    )
    adds = _posts_to(httpserver, "/control/rewrite/add")
    assert {"domain": "grafana.lab.example.com", "answer": "10.0.0.5"} in adds
    assert {"domain": "netbox.lab.example.com", "answer": "10.0.0.9"} in adds


def test_rewrite_sync_prune_removes_unmanaged(httpserver):
    _login(httpserver)
    httpserver.expect_request("/control/rewrite/list").respond_with_json(
        [
            {"domain": "grafana.lab.example.com", "answer": "10.0.0.5"},
            {"domain": "stale.lab.example.com", "answer": "10.0.0.99"},
        ]
    )
    httpserver.expect_request(
        "/control/rewrite/delete", method="POST"
    ).respond_with_json({})
    payload = json.dumps({"grafana.lab.example.com": "10.0.0.5"})
    r = runner.invoke(
        ag.app,
        [
            "--server-url",
            httpserver.url_for(""),
            "--json",
            "rewrite-sync",
            "--file",
            "-",
            "--prune",
        ],
        input=payload,
    )
    assert r.exit_code == 0, r.output
    doc = json.loads(r.output)
    assert doc["unchanged"] == ["grafana.lab.example.com"]
    assert doc["pruned"] == ["stale.lab.example.com"]
    assert {"domain": "stale.lab.example.com", "answer": "10.0.0.99"} in _posts_to(
        httpserver, "/control/rewrite/delete"
    )


# --- HA: --node targeting -----------------------------------------------------


def test_node_option_targets_specific_host(httpserver, monkeypatch):
    monkeypatch.setattr(ag, "PORT", httpserver.port)
    tofu_json = {
        "hosts": {"value": {"primary": {"name": "p", "ipv4": httpserver.host}}}
    }
    monkeypatch.setattr(subprocess, "run", _fake_subprocess_run(tofu_json))
    _login(httpserver)
    httpserver.expect_request("/control/status").respond_with_json(
        {"running": True, "version": "v0.107.52", "dns_addresses": ["10.0.0.5"]}
    )
    r = runner.invoke(ag.app, ["--node", "primary", "--json", "status"])
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)["running"] is True


def test_node_not_in_hosts_dies(monkeypatch):
    tofu_json = {"hosts": {"value": {"primary": {"name": "p", "ipv4": "10.0.0.2"}}}}
    monkeypatch.setattr(subprocess, "run", _fake_subprocess_run(tofu_json))
    r = runner.invoke(ag.app, ["--node", "tertiary", "status"])
    assert r.exit_code == 1, r.output
    assert "not in tofu hosts output" in r.output


# --- HA: fan-out inside `check` -----------------------------------------------


def test_check_ha_mode_all_nodes_and_vip_pass(httpserver, monkeypatch):
    monkeypatch.setattr(ag, "PORT", httpserver.port)
    monkeypatch.setattr(
        subprocess,
        "run",
        _fake_subprocess_run(
            _ha_tofu_doc(httpserver.host), dig_stdout="93.184.216.34\n"
        ),
    )
    _login(httpserver)
    httpserver.expect_request("/control/status").respond_with_json(
        {"running": True, "version": "v0.107.52", "dns_addresses": ["10.0.0.5"]}
    )
    httpserver.expect_request("/control/dns_info").respond_with_json(
        {"upstream_dns": ["127.0.0.1:5335"], "protection_enabled": True}
    )
    r = runner.invoke(ag.app, ["--json", "check"])
    assert r.exit_code == 0, r.output
    doc = json.loads(r.output)
    assert doc["ok"] is True
    names = {c["name"]: c["status"] for c in doc["checks"]}
    assert names["primary answers /status"] == "pass"
    assert names["secondary answers /status"] == "pass"
    assert names["VIP answers DNS"] == "pass"


def test_check_ha_mode_node_down_fails(httpserver, monkeypatch):
    monkeypatch.setattr(ag, "PORT", httpserver.port)
    tofu_json = {
        "hosts": {
            "value": {
                "primary": {"name": "p", "ipv4": httpserver.host},
                # 127.0.0.2 is loopback but nothing listens there -> connection refused.
                "secondary": {"name": "s", "ipv4": "127.0.0.2"},
            }
        },
        "enabled_features": {"value": {"ha": True}},
        "dns_endpoint": {"value": "10.10.10.99"},
        "dns_rewrite_target": {"value": httpserver.host},
    }
    monkeypatch.setattr(subprocess, "run", _fake_subprocess_run(tofu_json))
    _login(httpserver)
    httpserver.expect_request("/control/status").respond_with_json(
        {"running": True, "version": "v0.107.52", "dns_addresses": ["10.0.0.5"]}
    )
    httpserver.expect_request("/control/dns_info").respond_with_json(
        {"upstream_dns": ["127.0.0.1:5335"], "protection_enabled": True}
    )
    r = runner.invoke(ag.app, ["--json", "--timeout", "2", "check"])
    assert r.exit_code == ag.dc.CHECK_FAIL_EXIT, r.output
    doc = json.loads(r.output)
    names = {c["name"]: c["status"] for c in doc["checks"]}
    assert names["primary answers /status"] == "pass"
    assert names["secondary answers /status"] == "fail"


def test_check_ha_mode_vip_not_answering_fails(httpserver, monkeypatch):
    monkeypatch.setattr(ag, "PORT", httpserver.port)
    monkeypatch.setattr(
        subprocess,
        "run",
        _fake_subprocess_run(_ha_tofu_doc(httpserver.host), dig_stdout=""),
    )
    _login(httpserver)
    httpserver.expect_request("/control/status").respond_with_json(
        {"running": True, "version": "v0.107.52", "dns_addresses": ["10.0.0.5"]}
    )
    httpserver.expect_request("/control/dns_info").respond_with_json(
        {"upstream_dns": ["127.0.0.1:5335"], "protection_enabled": True}
    )
    r = runner.invoke(ag.app, ["--json", "check"])
    assert r.exit_code == ag.dc.CHECK_FAIL_EXIT, r.output
    doc = json.loads(r.output)
    names = {c["name"]: c["status"] for c in doc["checks"]}
    assert names["VIP answers DNS"] == "fail"


def test_check_single_mode_skips_ha_block(httpserver, monkeypatch):
    monkeypatch.setattr(ag, "PORT", httpserver.port)
    tofu_json = {
        "hosts": {"value": {"server": {"name": "x", "ipv4": httpserver.host}}},
        "dns_endpoint": {"value": httpserver.host},
        "dns_rewrite_target": {"value": httpserver.host},
    }
    monkeypatch.setattr(subprocess, "run", _fake_subprocess_run(tofu_json))
    _login(httpserver)
    httpserver.expect_request("/control/status").respond_with_json(
        {"running": True, "version": "v0.107.52", "dns_addresses": ["10.0.0.5"]}
    )
    httpserver.expect_request("/control/dns_info").respond_with_json(
        {"upstream_dns": ["127.0.0.1:5335"], "protection_enabled": True}
    )
    r = runner.invoke(ag.app, ["--json", "check"])
    assert r.exit_code == 0, r.output
    doc = json.loads(r.output)
    names = {c["name"] for c in doc["checks"]}
    assert not any("answers /status" in n or n == "VIP answers DNS" for n in names)


# --- HA: `sync-status` ---------------------------------------------------------


def test_sync_status_ha_mode_reports_journal(monkeypatch):
    tofu_json = {
        "hosts": {"value": {"primary": {"name": "p", "ipv4": "10.0.0.2"}}},
        "enabled_features": {"value": {"ha": True}},
    }
    monkeypatch.setattr(
        subprocess,
        "run",
        _fake_subprocess_run(tofu_json, ssh_result=(0, "active\nsome lines\n", "")),
    )
    r = runner.invoke(ag.app, ["--json", "sync-status"])
    assert r.exit_code == 0, r.output
    doc = json.loads(r.output)
    assert doc["host"] == "10.0.0.2"
    assert doc["returncode"] == 0
    assert "active" in doc["stdout"]


def test_sync_status_non_ha_mode_dies(monkeypatch):
    tofu_json = {"hosts": {"value": {"server": {"name": "x", "ipv4": "10.0.0.1"}}}}
    monkeypatch.setattr(subprocess, "run", _fake_subprocess_run(tofu_json))
    r = runner.invoke(ag.app, ["sync-status"])
    assert r.exit_code == 1, r.output
    assert "only meaningful in HA mode" in r.output


def test_sync_status_ssh_failure_exit_code(monkeypatch):
    tofu_json = {
        "hosts": {"value": {"primary": {"name": "p", "ipv4": "10.0.0.2"}}},
        "enabled_features": {"value": {"ha": True}},
    }
    monkeypatch.setattr(
        subprocess,
        "run",
        _fake_subprocess_run(tofu_json, ssh_result=(1, "", "connection refused")),
    )
    r = runner.invoke(ag.app, ["--json", "sync-status"])
    assert r.exit_code == ag.dc.CHECK_FAIL_EXIT, r.output
