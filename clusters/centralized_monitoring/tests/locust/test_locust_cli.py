"""Hermetic tests for locust_cli.

Drives the CLI via typer's CliRunner. `--server-url` avoids any `tofu` invocation,
and `_run_locust` is monkeypatched to a fake so no real swarm is launched — tests
assert argv construction and the `check` exit-code contract (0 pass / 2 fail).
"""

import csv
import json

import locust_cli as lc
from typer.testing import CliRunner

runner = CliRunner()
BASE = "http://10.0.0.5:5080"


def _run(*args):
    return runner.invoke(lc.app, ["--server-url", BASE, *args])


def _write_stats(prefix, requests, failures):
    with open(prefix + "_stats.csv", "w", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(["Type", "Name", "Request Count", "Failure Count"])
        writer.writerow(["POST", "/api/default/[stream]/_json", requests, failures])
        writer.writerow(["", "Aggregated", requests, failures])


# --- targets -----------------------------------------------------------------


def test_targets_json_lists_all_endpoints():
    r = runner.invoke(lc.app, ["--server-url", BASE, "--json", "targets"])
    assert r.exit_code == 0, r.output
    data = json.loads(r.output)
    services = {row["service"] for row in data}
    assert {"openobserve", "otlp-http", "statsd", "prometheus", "grafana"} <= services
    assert any("10.0.0.5:5080" in row["endpoint"] for row in data)
    assert any("udp://10.0.0.5:8125" == row["endpoint"] for row in data)


def test_targets_table_renders():
    r = _run("targets")
    assert r.exit_code == 0, r.output
    assert "openobserve" in r.output
    assert "10.0.0.5" in r.output


# --- run (argv construction + env injection) ---------------------------------


def test_run_web_builds_argv(monkeypatch):
    captured = {}

    def fake_run(argv, env):
        captured["argv"] = argv
        captured["env"] = env
        return 0

    monkeypatch.setattr(lc, "_run_locust", fake_run)
    r = _run("run")  # web UI is the default
    assert r.exit_code == 0, r.output
    argv = captured["argv"]
    assert argv[argv.index("-f") + 1].endswith("monitoring.py")
    assert "--web-port" in argv and "8089" in argv
    assert "--headless" not in argv
    assert captured["env"]["LOCUST_TARGET_IP"] == "10.0.0.5"
    assert captured["env"]["OO_USER"] == "admin@example.com"
    assert captured["env"]["OO_PASSWORD"] == "Complexpass#123"


def test_run_headless_builds_argv(monkeypatch):
    captured = {}

    def fake_run(argv, env):
        captured["argv"] = argv
        return 0

    monkeypatch.setattr(lc, "_run_locust", fake_run)
    r = _run(
        "--headless", "--users", "7", "--spawn-rate", "3", "--run-time", "20s", "run"
    )
    assert r.exit_code == 0, r.output
    argv = captured["argv"]
    assert "--headless" in argv
    assert argv[argv.index("-u") + 1] == "7"
    assert argv[argv.index("-r") + 1] == "3.0"
    assert argv[argv.index("-t") + 1] == "20s"
    assert "--web-port" not in argv


def test_run_propagates_locust_exit_code(monkeypatch):
    monkeypatch.setattr(lc, "_run_locust", lambda argv, env: 1)
    r = _run("--headless", "-t", "1s", "run")
    assert r.exit_code == 1


# --- check (exit-code contract) ----------------------------------------------


def test_check_passes_when_requests_fired_no_failures(monkeypatch):
    def fake_run(argv, env):
        prefix = argv[argv.index("--csv") + 1]
        _write_stats(prefix, 42, 0)
        return 0

    monkeypatch.setattr(lc, "_run_locust", fake_run)
    r = _run("--json", "check")
    assert r.exit_code == 0, r.output
    payload = json.loads(r.output)
    assert payload["ok"] is True
    names = {c["name"]: c["status"] for c in payload["checks"]}
    assert names["target resolved"] == "pass"
    assert names["load ran"] == "pass"
    assert names["no failures"] == "pass"


def test_check_fails_on_failures(monkeypatch):
    def fake_run(argv, env):
        prefix = argv[argv.index("--csv") + 1]
        _write_stats(prefix, 42, 5)
        return 1

    monkeypatch.setattr(lc, "_run_locust", fake_run)
    r = _run("--json", "check")
    assert r.exit_code == 2
    names = {c["name"]: c["status"] for c in json.loads(r.output)["checks"]}
    assert names["no failures"] == "fail"


def test_check_fails_when_no_requests(monkeypatch):
    def fake_run(argv, env):
        prefix = argv[argv.index("--csv") + 1]
        _write_stats(prefix, 0, 0)
        return 0

    monkeypatch.setattr(lc, "_run_locust", fake_run)
    r = _run("--json", "check")
    assert r.exit_code == 2
    names = {c["name"]: c["status"] for c in json.loads(r.output)["checks"]}
    assert names["load ran"] == "fail"


def test_check_fails_when_stats_missing(monkeypatch):
    # locust never wrote a CSV (e.g. it crashed) -> load ran fails.
    monkeypatch.setattr(lc, "_run_locust", lambda argv, env: 1)
    r = _run("--json", "check")
    assert r.exit_code == 2
    names = {c["name"]: c["status"] for c in json.loads(r.output)["checks"]}
    assert names["load ran"] == "fail"


def test_check_fails_on_unresolved_target(monkeypatch):
    def boom(**kwargs):
        raise RuntimeError("no tofu output for centralized_monitoring")

    monkeypatch.setattr(lc.oc, "resolve_target", boom)
    # No --server-url, so resolution goes through the (patched) tofu path.
    r = runner.invoke(lc.app, ["--json", "check"])
    assert r.exit_code == 2
    names = {c["name"]: c["status"] for c in json.loads(r.output)["checks"]}
    assert names["target resolved"] == "fail"
