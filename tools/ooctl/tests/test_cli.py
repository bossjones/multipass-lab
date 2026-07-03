"""Tests for ooctl.cli — the typer CLI wiring (hermetic via httpserver)."""

from __future__ import annotations

import json

import yaml
from typer.testing import CliRunner

from ooctl.cli import app

runner = CliRunner()


def _env(httpserver):
    return {"OOCTL_ENDPOINT": httpserver.url_for("").rstrip("/")}


def _invoke(args, config_file, httpserver=None):
    env = _env(httpserver) if httpserver is not None else {}
    return runner.invoke(app, ["--config", str(config_file), *args], env=env)


# -- configure -------------------------------------------------------------


def test_configure_list_shows_profiles_and_redacts_password(config_file):
    result = _invoke(["configure", "list"], config_file)
    assert result.exit_code == 0
    assert "default" in result.output
    assert "admin@example.com" in result.output
    assert "Complexpass#123" not in result.output  # redacted


def test_configure_add_writes_new_profile(config_file):
    result = _invoke(
        [
            "configure",
            "add",
            "staging",
            "--endpoint",
            "http://stage:5080",
            "--username",
            "s@x.com",
            "--password",
            "secret",
        ],
        config_file,
    )
    assert result.exit_code == 0
    data = yaml.safe_load(config_file.read_text())
    assert "staging" in data["profiles"]
    assert data["profiles"]["staging"]["endpoint"] == "http://stage:5080"


def test_unknown_profile_errors(config_file):
    result = _invoke(["--profile", "ghost", "health"], config_file)
    assert result.exit_code != 0
    assert "ghost" in result.output


# -- health ----------------------------------------------------------------


def test_health_ok_exit_zero(config_file, httpserver):
    httpserver.expect_request("/healthz").respond_with_data("ok", status=200)
    result = _invoke(["health"], config_file, httpserver)
    assert result.exit_code == 0


def test_health_down_exit_nonzero(config_file, httpserver):
    httpserver.expect_request("/healthz").respond_with_data("bad", status=503)
    result = _invoke(["health"], config_file, httpserver)
    assert result.exit_code != 0


# -- streams ---------------------------------------------------------------


def test_streams_list_json(config_file, httpserver):
    httpserver.expect_request("/api/default/streams").respond_with_json(
        {"list": [{"name": "syslog", "stream_type": "logs"}]}
    )
    result = _invoke(["streams", "list", "--json"], config_file, httpserver)
    assert result.exit_code == 0
    assert json.loads(result.output)[0]["name"] == "syslog"


# -- logs search (SSE) -----------------------------------------------------


def test_logs_search_renders_hits(config_file, httpserver):
    body = (
        'event: search_response_hits\ndata: {"hits": [{"_timestamp": 1000000, '
        '"message": "boot complete"}]}\n\n'
        "event: done\ndata: {}\n\n"
    )
    httpserver.expect_request("/api/default/_search_stream", method="POST").respond_with_data(
        body, content_type="text/event-stream"
    )
    result = _invoke(
        ["logs", "search", "--stream", "default", "--since", "1h"],
        config_file,
        httpserver,
    )
    assert result.exit_code == 0
    assert "boot complete" in result.output


# -- logs tail (no -f = single bounded window via _search) -----------------


def test_logs_tail_without_follow_single_window(config_file, httpserver):
    # timestamp must fall inside the --since window (future-ish value is fine here)
    httpserver.expect_request("/api/default/_search", method="POST").respond_with_json(
        {"hits": [{"_timestamp": 2_000_000_000_000_000, "log": "hello world"}]}
    )
    result = _invoke(
        ["logs", "tail", "--stream", "default", "--since", "5m"],
        config_file,
        httpserver,
    )
    assert result.exit_code == 0
    assert "hello world" in result.output


def test_logs_search_requires_stream_or_sql(config_file):
    result = _invoke(["logs", "search"], config_file)
    assert result.exit_code != 0
