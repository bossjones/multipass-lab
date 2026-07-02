"""Hermetic tests for the monitoring locustfile.

Asserts request-shape of the pure helpers and drives the OpenObserve ingest path
against a pytest-httpserver + the StatsD path against a stub UDP socket — no swarm.
"""

import socket

import httpx
import monitoring as m


# --- pure builders -----------------------------------------------------------


def test_ingest_records_shape():
    records = m.ingest_records(3)
    assert len(records) == 3
    for rec in records:
        assert {"_timestamp", "level", "message", "service", "trace_id"} <= rec.keys()


def test_ingest_request_targets_json_endpoint():
    req = m.ingest_request(
        org="myorg", stream="loadtest", user="u", password="p", records=[{"a": 1}]
    )
    assert req["url"] == "/api/myorg/loadtest/_json"
    assert req["json"] == [{"a": 1}]
    assert req["auth"] == ("u", "p")


def test_otlp_payload_shape():
    payload = m.otlp_log_payload("hello", service="svc")
    log = payload["resourceLogs"][0]["scopeLogs"][0]["logRecords"][0]
    assert log["body"]["stringValue"] == "hello"
    assert log["severityText"] == "INFO"
    attrs = payload["resourceLogs"][0]["resource"]["attributes"]
    assert attrs[0]["value"]["stringValue"] == "svc"


def test_statsd_line_format():
    assert m.statsd_line("loadtest.requests", 1, "c") == b"loadtest.requests:1|c"
    assert (
        m.statsd_line("loadtest.latency_ms", 42, "ms") == b"loadtest.latency_ms:42|ms"
    )


# --- OpenObserve ingest end-to-end (against pytest-httpserver) ----------------


def test_ingest_hits_openobserve_with_basic_auth(httpserver):
    httpserver.expect_request(
        "/api/default/loadtest/_json", method="POST"
    ).respond_with_json({"status": "ok"})
    req = m.ingest_request(
        org="default",
        stream="loadtest",
        user="admin@example.com",
        password="Complexpass#123",
        records=[{"level": "INFO", "message": "hi"}],
    )
    with httpx.Client(base_url=httpserver.url_for("")) as client:
        resp = client.post(req["url"], json=req["json"], auth=req["auth"])
    assert resp.status_code == 200

    request, _ = httpserver.log[-1]
    assert request.headers["Authorization"].startswith("Basic ")
    assert request.get_json() == [{"level": "INFO", "message": "hi"}]


# --- StatsD over UDP (against a stub receiver) --------------------------------


def test_statsd_user_sends_udp_and_fires_event(monkeypatch):
    receiver = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    receiver.bind(("127.0.0.1", 0))
    receiver.settimeout(2)
    port = receiver.getsockname()[1]

    monkeypatch.setenv("LOCUST_TARGET_IP", "127.0.0.1")
    monkeypatch.setenv("LOCUST_STATSD_PORT", str(port))

    from locust.env import Environment

    fired = []
    env = Environment(user_classes=[m.StatsdUser])
    env.events.request.add_listener(lambda **kw: fired.append(kw))

    user = m.StatsdUser(env)
    user.on_start()
    try:
        user.emit()
        data, _ = receiver.recvfrom(1024)
    finally:
        user.on_stop()
        receiver.close()

    assert data.startswith(b"loadtest.")
    assert b"|" in data
    assert fired, "events.request should fire per StatsD send"
    assert fired[0]["request_type"] == "STATSD"
