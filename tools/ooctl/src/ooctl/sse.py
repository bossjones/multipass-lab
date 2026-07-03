"""Minimal async Server-Sent Events (SSE) parser.

OpenObserve's ``_search_stream`` endpoint returns ``text/event-stream`` frames of
the form::

    event: <type>\\n
    data: <json>\\n
    \\n

``parse_sse`` consumes a line iterator (e.g. ``httpx.Response.aiter_lines()``) and
yields ``(event, data)`` tuples, where ``data`` is the parsed JSON object (or
``{"raw": <text>}`` when the payload is not JSON).
"""

from __future__ import annotations

import json
from collections.abc import AsyncIterator

__all__ = ["parse_sse"]


def _decode(data_lines: list[str]) -> dict:
    text = "\n".join(data_lines)
    try:
        obj = json.loads(text)
    except (json.JSONDecodeError, ValueError):
        return {"raw": text}
    return obj if isinstance(obj, dict) else {"raw": obj}


async def parse_sse(lines: AsyncIterator[str]) -> AsyncIterator[tuple[str, dict]]:
    """Yield ``(event, data)`` frames from an SSE line stream."""
    event: str | None = None
    data: list[str] = []

    async for raw_line in lines:
        line = raw_line.rstrip("\n").rstrip("\r")

        if line == "":  # end of a frame -> dispatch
            if event is not None or data:
                yield (event or "message", _decode(data))
            event = None
            data = []
            continue

        if line.startswith(":"):  # comment / heartbeat
            continue

        field, _, value = line.partition(":")
        if value.startswith(" "):  # strip a single leading space
            value = value[1:]

        if field == "event":
            event = value
        elif field == "data":
            data.append(value)
        # other fields (id, retry) are ignored

    # flush a trailing frame with no terminating blank line
    if event is not None or data:
        yield (event or "message", _decode(data))
