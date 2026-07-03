"""Tests for ooctl.client — the async OpenObserve HTTP client (hermetic)."""

from __future__ import annotations

import base64

import pytest

from ooctl.client import OpenObserveClient, SearchError

AUTH = "Basic " + base64.b64encode(b"admin@example.com:Complexpass#123").decode()


def _client(httpserver) -> OpenObserveClient:
    return OpenObserveClient(
        endpoint=httpserver.url_for("").rstrip("/"),
        organization="default",
        username="admin@example.com",
        password="Complexpass#123",
    )


async def test_health_ok(httpserver):
    httpserver.expect_request("/healthz").respond_with_data("ok", status=200)
    async with _client(httpserver) as c:
        assert await c.health() is True


async def test_health_down_on_5xx(httpserver):
    httpserver.expect_request("/healthz").respond_with_data("boom", status=503)
    async with _client(httpserver) as c:
        assert await c.health() is False


async def test_health_down_on_connection_error():
    c = OpenObserveClient(
        endpoint="http://127.0.0.1:1",
        organization="default",
        username="u",
        password="p",
        timeout=0.5,
    )
    async with c:
        assert await c.health() is False


async def test_streams_lists_and_sends_auth(httpserver):
    httpserver.expect_request(
        "/api/default/streams", headers={"Authorization": AUTH}
    ).respond_with_json({"list": [{"name": "default"}, {"name": "syslog"}]})
    async with _client(httpserver) as c:
        streams = await c.streams()
    assert [s["name"] for s in streams] == ["default", "syslog"]


async def test_streams_type_filter_passed_as_query(httpserver):
    httpserver.expect_request(
        "/api/default/streams", query_string={"type": "logs"}
    ).respond_with_json({"list": [{"name": "applogs"}]})
    async with _client(httpserver) as c:
        streams = await c.streams(stream_type="logs")
    assert streams == [{"name": "applogs"}]


async def test_search_posts_body_and_returns_hits(httpserver):
    def _handler(request):
        from werkzeug.wrappers import Response

        body = request.get_json()
        assert body["query"]["sql"] == "SELECT * FROM default"
        assert body["query"]["start_time"] == 100
        assert body["query"]["end_time"] == 200
        assert body["query"]["size"] == 50
        assert request.headers["Authorization"] == AUTH
        return Response(
            '{"hits": [{"_timestamp": 150, "log": "hi"}], "total": 1}',
            content_type="application/json",
        )

    httpserver.expect_request("/api/default/_search", method="POST").respond_with_handler(_handler)
    async with _client(httpserver) as c:
        hits = await c.search(sql="SELECT * FROM default", start_time=100, end_time=200, size=50)
    assert hits == [{"_timestamp": 150, "log": "hi"}]


async def test_search_raises_on_401(httpserver):
    httpserver.expect_request("/api/default/_search", method="POST").respond_with_data(
        "unauthorized", status=401
    )
    async with _client(httpserver) as c:
        with pytest.raises(SearchError):
            await c.search(sql="SELECT * FROM default", start_time=0, end_time=1)


def _sse(*frames: tuple[str, str]) -> str:
    return "".join(f"event: {ev}\ndata: {data}\n\n" for ev, data in frames)


async def test_search_stream_yields_hits_until_done(httpserver):
    body = _sse(
        ("search_response_metadata", '{"results": {"total": 2}}'),
        ("search_response_hits", '{"hits": [{"_timestamp": 1, "log": "a"}]}'),
        ("search_response_hits", '{"hits": [{"_timestamp": 2, "log": "b"}]}'),
        ("done", "{}"),
    )
    httpserver.expect_request("/api/default/_search_stream", method="POST").respond_with_data(
        body, content_type="text/event-stream"
    )
    async with _client(httpserver) as c:
        hits = [
            h async for h in c.search_stream(sql="SELECT * FROM default", start_time=0, end_time=10)
        ]
    assert hits == [{"_timestamp": 1, "log": "a"}, {"_timestamp": 2, "log": "b"}]


async def test_search_stream_raises_on_error_event(httpserver):
    body = _sse(("error", '{"code": 500, "message": "bad query"}'))
    httpserver.expect_request("/api/default/_search_stream", method="POST").respond_with_data(
        body, content_type="text/event-stream"
    )
    async with _client(httpserver) as c:
        with pytest.raises(SearchError) as exc:
            async for _ in c.search_stream(sql="SELECT * FROM default", start_time=0, end_time=10):
                pass
    assert "bad query" in str(exc.value)
