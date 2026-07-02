"""End-to-end: OpenObserve is really INGESTING metrics + logs.

Proves the ingestion paths this cluster wires up (see specs/openobserve.md):
  * metrics  — Prometheus remote_write lands scraped series in OpenObserve (PromQL `up`).
  * logs     — the server's OTel Collector ships container + host logs (container_logs /
               host_logs streams).
  * k0s logs — the k0s otelcol-contrib agent (endpoint injected post-apply) ships host +
               pod logs (k0s_host / k0s_pods streams).

All requests run on the server VM against OpenObserve on localhost:5080 with the root
basic-auth. Flag-gated features are skipped (not failed) when their flag is off.
"""

import json
import time

import pytest

OO = "http://localhost:5080"
AUTH = "admin@example.com:Complexpass#123"
ORG = "default"


def _oo_get(host, path, timeout=240):
    """Poll a GET endpoint on OpenObserve (basic auth) until it returns parseable JSON."""
    url = f"{OO}{path}"
    deadline = time.time() + timeout
    last = ""
    while time.time() < deadline:
        res = host.run(f"curl -fsS -u '{AUTH}' '{url}'")
        if res.rc == 0 and res.stdout.strip():
            try:
                return json.loads(res.stdout)
            except json.JSONDecodeError:
                last = res.stdout
        time.sleep(5)
    pytest.fail(f"no JSON from {url} after {timeout}s (last: {last[:200]})")


def _stream_names(host):
    data = _oo_get(host, f"/api/{ORG}/streams")
    items = data.get("list", data) if isinstance(data, dict) else data
    return {s.get("name") for s in items}


def _wait_for_streams(host, wanted, timeout=300):
    """Poll until every stream name in `wanted` exists; return the final name set."""
    deadline = time.time() + timeout
    names = set()
    while time.time() < deadline:
        names = _stream_names(host)
        if wanted <= names:
            return names
        time.sleep(10)
    return names


def _search_hits(host, stream, timeout=300):
    """Poll a SQL search over `stream` until it returns ≥1 row; return the hit count."""
    now_us = int(time.time() * 1_000_000)
    body = json.dumps(
        {
            "query": {
                "sql": f'SELECT * FROM "{stream}"',
                "start_time": now_us - 3_600_000_000,
                "end_time": now_us,
                "size": 1,
            }
        }
    )
    deadline = time.time() + timeout
    while time.time() < deadline:
        res = host.run(
            f"curl -fsS -u '{AUTH}' -H 'Content-Type: application/json' "
            f"-d '{body}' '{OO}/api/{ORG}/_search'"
        )
        if res.rc == 0 and res.stdout.strip():
            try:
                hits = json.loads(res.stdout).get("hits") or []
            except json.JSONDecodeError:
                hits = []
            if hits:
                return len(hits)
        time.sleep(10)
    return 0


def _skip_unless(enabled_exporters, flag):
    if flag not in enabled_exporters:
        pytest.skip(f"{flag} disabled")


def test_metrics_ingested_via_remote_write(server, enabled_exporters):
    """PromQL `up` returns series from OpenObserve (Prometheus remote_write is flowing)."""
    _skip_unless(enabled_exporters, "enable_openobserve")
    # Give remote_write time to push the first batch after boot.
    deadline = time.time() + 300
    result = []
    while time.time() < deadline:
        data = _oo_get(server, f"/api/{ORG}/prometheus/api/v1/query?query=up")
        result = (data.get("data") or {}).get("result") or []
        if result:
            return
        time.sleep(10)
    pytest.fail(f"no `up` series in OpenObserve after 300s: {result}")


def test_server_log_streams_created(server, enabled_exporters):
    """The OTel Collector created the container_logs + host_logs streams."""
    _skip_unless(enabled_exporters, "enable_openobserve")
    _skip_unless(enabled_exporters, "enable_otel")
    names = _wait_for_streams(server, {"container_logs", "host_logs"})
    assert {"container_logs", "host_logs"} <= names, f"missing log streams: {names}"


@pytest.mark.parametrize("stream", ["container_logs", "host_logs"])
def test_server_logs_have_rows(server, enabled_exporters, stream):
    """Each server log stream has at least one recent row."""
    _skip_unless(enabled_exporters, "enable_openobserve")
    _skip_unless(enabled_exporters, "enable_otel")
    assert _search_hits(server, stream) >= 1, f"no rows ingested into {stream}"


def test_k0s_log_streams_have_rows(server, enabled_exporters):
    """The post-apply k0s agent ships host + pod logs (k0s_host / k0s_pods streams)."""
    _skip_unless(enabled_exporters, "enable_k0s_log_shipping")
    names = _wait_for_streams(server, {"k0s_host", "k0s_pods"})
    assert {"k0s_host", "k0s_pods"} <= names, f"missing k0s log streams: {names}"
    assert _search_hits(server, "k0s_host") >= 1, "no rows in k0s_host"
    assert _search_hits(server, "k0s_pods") >= 1, "no rows in k0s_pods"
