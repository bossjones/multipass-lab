"""Tests for ooctl.sse — parsing an SSE line stream into (event, data) frames."""

from __future__ import annotations

from collections.abc import AsyncIterator

from ooctl.sse import parse_sse


async def _alines(lines: list[str]) -> AsyncIterator[str]:
    for line in lines:
        yield line


async def _collect(lines: list[str]) -> list[tuple[str, dict]]:
    return [frame async for frame in parse_sse(_alines(lines))]


async def test_single_frame():
    frames = await _collect(
        [
            "event: search_response_hits",
            'data: {"hits": [{"log": "a"}]}',
            "",
        ]
    )
    assert frames == [("search_response_hits", {"hits": [{"log": "a"}]})]


async def test_multiple_frames():
    frames = await _collect(
        [
            "event: progress",
            'data: {"percent": 50}',
            "",
            "event: done",
            "data: {}",
            "",
        ]
    )
    assert frames == [("progress", {"percent": 50}), ("done", {})]


async def test_multiline_data_is_joined_with_newlines():
    frames = await _collect(
        [
            "event: message",
            "data: line1",
            "data: line2",
            "",
        ]
    )
    # non-JSON multiline data is returned under a "raw" key
    assert frames == [("message", {"raw": "line1\nline2"})]


async def test_default_event_is_message():
    frames = await _collect(['data: {"x": 1}', ""])
    assert frames == [("message", {"x": 1})]


async def test_comment_and_heartbeat_lines_ignored():
    frames = await _collect(
        [
            ": this is a comment / heartbeat",
            "event: done",
            "data: {}",
            "",
        ]
    )
    assert frames == [("done", {})]


async def test_final_frame_without_trailing_blank_line():
    frames = await _collect(
        [
            "event: done",
            "data: {}",
        ]
    )
    assert frames == [("done", {})]


async def test_field_with_space_after_colon_and_without():
    # SSE spec: one optional leading space after the colon is stripped.
    frames = await _collect(["event:done", 'data:{"n":1}', ""])
    assert frames == [("done", {"n": 1})]


async def test_blank_stream_yields_nothing():
    assert await _collect([]) == []
    assert await _collect(["", "", ""]) == []
