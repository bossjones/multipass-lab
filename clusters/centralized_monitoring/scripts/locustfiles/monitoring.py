"""Locust load generators for the `centralized_monitoring` cluster.

Driven by `locust_cli.py`, which resolves the server VM IP from `tofu output`
and passes it (plus OpenObserve creds) to Locust via environment variables:

    LOCUST_TARGET_IP    server VM IP                  (default 127.0.0.1)
    OO_USER             OpenObserve basic-auth user    (default admin@example.com)
    OO_PASSWORD         OpenObserve basic-auth password (default Complexpass#123)
    OO_ORG              OpenObserve org                (default "default")
    OO_STREAM           ingest stream name             (default "loadtest")
    LOCUST_STATSD_PORT  statsd UDP port                (default 8125)

Each `User` targets a different service port on the same host, all derived from
the one resolved IP. The request-building logic lives in importable pure helpers
(`ingest_records`, `ingest_request`, `otlp_log_payload`, `statsd_line`) so the
hermetic suite can assert request shape without launching a swarm.
"""

from __future__ import annotations

import os
import socket
import time

from faker import Faker
from locust import HttpUser, User, between, task

fake = Faker()

# --- resolved targets (injected by locust_cli.py) ----------------------------
TARGET_IP = os.environ.get("LOCUST_TARGET_IP", "127.0.0.1")
OO_USER = os.environ.get("OO_USER", "admin@example.com")
OO_PASSWORD = os.environ.get("OO_PASSWORD", "Complexpass#123")
OO_ORG = os.environ.get("OO_ORG", "default")
OO_STREAM = os.environ.get("OO_STREAM", "loadtest")

OPENOBSERVE_PORT = 5080
OTLP_HTTP_PORT = 4318
STATSD_PORT = int(os.environ.get("LOCUST_STATSD_PORT", "8125"))
PROMETHEUS_PORT = 9090
GRAFANA_PORT = 3000


def _host(port: int) -> str:
    return f"http://{TARGET_IP}:{port}"


# --- pure request builders (testable without a running swarm) ----------------


def ingest_records(n: int = 5, faker: Faker | None = None) -> list[dict]:
    """A batch of synthetic OpenObserve log records."""
    fk = faker or fake
    now_ms = int(time.time() * 1000)
    levels = ["INFO", "WARN", "ERROR", "DEBUG"]
    return [
        {
            "_timestamp": now_ms,
            "level": fk.random_element(levels),
            "message": fk.sentence(),
            "service": fk.word(),
            "trace_id": fk.uuid4(),
        }
        for _ in range(n)
    ]


def ingest_request(
    *,
    org: str = OO_ORG,
    stream: str = OO_STREAM,
    user: str = OO_USER,
    password: str = OO_PASSWORD,
    records: list[dict] | None = None,
) -> dict:
    """kwargs for a `client.post(...)` that ingests a JSON array into OpenObserve."""
    return {
        "url": f"/api/{org}/{stream}/_json",
        "json": records if records is not None else ingest_records(),
        "auth": (user, password),
    }


def otlp_log_payload(
    message: str | None = None, service: str = "locust-loadtest"
) -> dict:
    """Minimal OTLP-JSON logs payload (POST :4318/v1/logs)."""
    return {
        "resourceLogs": [
            {
                "resource": {
                    "attributes": [
                        {"key": "service.name", "value": {"stringValue": service}}
                    ]
                },
                "scopeLogs": [
                    {
                        "logRecords": [
                            {
                                "timeUnixNano": str(int(time.time() * 1_000_000_000)),
                                "severityText": "INFO",
                                "body": {
                                    "stringValue": message
                                    or "synthetic log from locust"
                                },
                            }
                        ]
                    }
                ],
            }
        ]
    }


def statsd_line(metric: str, value, kind: str) -> bytes:
    """Encode a StatsD line, e.g. ``statsd_line("loadtest.requests", 1, "c")``."""
    return f"{metric}:{value}|{kind}".encode()


# --- Users -------------------------------------------------------------------


class OpenObserveIngestUser(HttpUser):
    """POST synthetic JSON logs into the OpenObserve ``loadtest`` stream (:5080)."""

    host = _host(OPENOBSERVE_PORT)
    weight = 3
    wait_time = between(0.5, 2)

    @task
    def ingest(self):
        req = ingest_request()
        self.client.post(
            req["url"],
            json=req["json"],
            auth=req["auth"],
            name=f"/api/{OO_ORG}/[stream]/_json",
        )


class OtlpUser(HttpUser):
    """POST OTLP-JSON logs to the OTel Collector (:4318)."""

    host = _host(OTLP_HTTP_PORT)
    weight = 2
    wait_time = between(0.5, 2)

    @task
    def logs(self):
        self.client.post("/v1/logs", json=otlp_log_payload(), name="/v1/logs")


class StatsdUser(User):
    """Fire StatsD counters/timers over UDP (:8125) → statsd_exporter → Prometheus."""

    weight = 2
    wait_time = between(0.5, 2)

    def on_start(self):
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._addr = (
            os.environ.get("LOCUST_TARGET_IP", TARGET_IP),
            int(os.environ.get("LOCUST_STATSD_PORT", STATSD_PORT)),
        )

    def on_stop(self):
        sock = getattr(self, "_sock", None)
        if sock is not None:
            sock.close()

    @task
    def emit(self):
        self._send("loadtest.requests", 1, "c")
        self._send("loadtest.latency_ms", fake.random_int(1, 500), "ms")

    def _send(self, metric: str, value, kind: str):
        line = statsd_line(metric, value, kind)
        start = time.time()
        exc = None
        try:
            self._sock.sendto(line, self._addr)
        except OSError as err:  # reconnect-worthy; report as a failure
            exc = err
        self.environment.events.request.fire(
            request_type="STATSD",
            name=metric,
            response_time=(time.time() - start) * 1000,
            response_length=len(line),
            exception=exc,
            context={},
        )


class QueryUser(HttpUser):
    """Generate read traffic against Prometheus (:9090) and Grafana (:3000)."""

    host = _host(PROMETHEUS_PORT)
    weight = 1
    wait_time = between(1, 3)

    @task(3)
    def prom_up(self):
        self.client.get("/api/v1/query?query=up", name="/api/v1/query?query=up")

    @task(1)
    def grafana_health(self):
        self.client.get(f"{_host(GRAFANA_PORT)}/api/health", name="grafana /api/health")
