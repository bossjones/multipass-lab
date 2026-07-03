"""Async OpenObserve HTTP client.

OpenObserve ships no read SDK, so this talks to the REST API directly with an
``httpx.AsyncClient`` (HTTP Basic auth). It exposes:

- ``search``        -> ``POST /api/{org}/_search`` (bounded query, returns hits)
- ``search_stream`` -> ``POST /api/{org}/_search_stream`` (SSE, yields hits)
- ``streams``       -> ``GET  /api/{org}/streams``
- ``health``        -> ``GET  /healthz``

Timestamps are microseconds since epoch (OpenObserve's ``_timestamp`` unit).
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from typing import Any

import httpx

from ooctl.sse import parse_sse

__all__ = ["OpenObserveClient", "SearchError"]

# SSE event types emitted by _search_stream (see specs/ooctl.md).
_HITS_EVENTS = {"search_response_hits"}
_TERMINAL_EVENTS = {"done", "cancelled"}


class SearchError(Exception):
    """Raised when OpenObserve returns an error status or an SSE error frame."""


class OpenObserveClient:
    """Async client for a single OpenObserve org, resolved from a Profile."""

    def __init__(
        self,
        *,
        endpoint: str,
        organization: str,
        username: str,
        password: str,
        timeout: float = 10.0,
        verify: bool = True,
    ) -> None:
        self.endpoint = endpoint.rstrip("/")
        self.organization = organization
        self._client = httpx.AsyncClient(
            base_url=self.endpoint,
            auth=(username, password),
            timeout=timeout,
            verify=verify,
        )

    async def __aenter__(self) -> OpenObserveClient:
        return self

    async def __aexit__(self, *exc: object) -> None:
        await self.aclose()

    async def aclose(self) -> None:
        await self._client.aclose()

    # -- endpoints ---------------------------------------------------------

    async def health(self) -> bool:
        """Return True if ``/healthz`` responds with a non-error status."""
        try:
            resp = await self._client.get("/healthz")
        except httpx.HTTPError:
            return False
        return resp.status_code < 400

    async def streams(self, *, stream_type: str | None = None) -> list[dict[str, Any]]:
        """List ingest streams (optionally filtered by ``stream_type``)."""
        params = {"type": stream_type} if stream_type else None
        resp = await self._client.get(f"/api/{self.organization}/streams", params=params)
        _raise_for_status(resp)
        return _as_list(resp.json())

    async def search(
        self,
        *,
        sql: str,
        start_time: int,
        end_time: int,
        size: int = 100,
        from_: int = 0,
    ) -> list[dict[str, Any]]:
        """Run a bounded ``_search`` and return its hits."""
        body = _query_body(sql, start_time, end_time, size, from_)
        resp = await self._client.post(f"/api/{self.organization}/_search", json=body)
        _raise_for_status(resp)
        data = resp.json()
        return data.get("hits", []) if isinstance(data, dict) else []

    async def search_stream(
        self,
        *,
        sql: str,
        start_time: int,
        end_time: int,
        size: int = 1000,
        from_: int = 0,
    ) -> AsyncIterator[dict[str, Any]]:
        """Stream ``_search_stream`` (SSE) and yield individual hits.

        Stops on a ``done``/``cancelled`` event; raises ``SearchError`` on an
        ``error`` event or a non-2xx status.
        """
        body = _query_body(sql, start_time, end_time, size, from_)
        async with self._client.stream(
            "POST", f"/api/{self.organization}/_search_stream", json=body
        ) as resp:
            if resp.status_code >= 400:
                await resp.aread()
                _raise_for_status(resp)
            async for event, data in parse_sse(resp.aiter_lines()):
                if event == "error":
                    msg = data.get("message") or data.get("raw") or "search error"
                    raise SearchError(f"stream error: {msg}")
                if event in _HITS_EVENTS:
                    for hit in data.get("hits", []):
                        yield hit
                elif event in _TERMINAL_EVENTS:
                    return


def _query_body(sql: str, start_time: int, end_time: int, size: int, from_: int) -> dict:
    return {
        "query": {
            "sql": sql,
            "start_time": start_time,
            "end_time": end_time,
            "from": from_,
            "size": size,
        }
    }


def _raise_for_status(resp: httpx.Response) -> None:
    if resp.status_code >= 400:
        raise SearchError(f"HTTP {resp.status_code}: {resp.text[:200]}")


def _as_list(payload: Any) -> list[dict[str, Any]]:
    """OpenObserve wraps stream lists as {"list": [...]}; tolerate a bare list."""
    if isinstance(payload, dict):
        return payload.get("list", [])
    if isinstance(payload, list):
        return payload
    return []
