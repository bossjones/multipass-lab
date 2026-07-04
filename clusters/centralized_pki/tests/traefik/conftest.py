"""Fixtures for traefik_cli hermetic tests: a tiny threaded HTTP server for probe_route."""

import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest


def _make_handler(status: int):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802 - stdlib method name
            self.send_response(status)
            self.end_headers()

        def log_message(self, *args):  # silence stderr noise
            pass

    return Handler


@pytest.fixture
def http_server():
    """Yields (ip, port) of a server that always answers 200."""
    server = HTTPServer(("127.0.0.1", 0), _make_handler(200))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield server.server_address
    server.shutdown()


@pytest.fixture
def http_server_503():
    """Yields (ip, port) of a server that always answers 503."""
    server = HTTPServer(("127.0.0.1", 0), _make_handler(503))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield server.server_address
    server.shutdown()
