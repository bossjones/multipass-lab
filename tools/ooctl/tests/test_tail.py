"""Tests for ooctl.tail — window advance, boundary dedup, and the follow loop."""

from __future__ import annotations

import asyncio

from ooctl.tail import build_tail_sql, follow, run_tail, select_new_hits


def _hit(ts: int, msg: str) -> dict:
    return {"_timestamp": ts, "log": msg}


# -- select_new_hits (pure window/dedup logic) -----------------------------


def test_select_all_new_on_first_window():
    hits = [_hit(3, "c"), _hit(1, "a"), _hit(2, "b")]
    emitted, last_ts, seen = select_new_hits(hits, last_ts=0, seen=set())
    assert [h["log"] for h in emitted] == ["a", "b", "c"]  # sorted by ts
    assert last_ts == 3
    assert len(seen) == 1  # only the record(s) at the max ts are tracked


def test_empty_poll_leaves_state_unchanged():
    emitted, last_ts, seen = select_new_hits([], last_ts=5, seen={"x"})
    assert emitted == []
    assert last_ts == 5
    assert seen == {"x"}


def test_boundary_record_not_re_emitted_across_polls():
    # poll 1
    hits1 = [_hit(1, "a"), _hit(2, "b")]
    emitted1, last_ts, seen = select_new_hits(hits1, last_ts=0, seen=set())
    assert [h["log"] for h in emitted1] == ["a", "b"]
    assert last_ts == 2
    # poll 2 re-returns the boundary record b (ts==2) plus a new c (ts==3)
    hits2 = [_hit(2, "b"), _hit(3, "c")]
    emitted2, last_ts, seen = select_new_hits(hits2, last_ts=last_ts, seen=seen)
    assert [h["log"] for h in emitted2] == ["c"]  # b deduped
    assert last_ts == 3


def test_two_records_sharing_max_ts_both_emitted_then_deduped():
    hits1 = [_hit(5, "a")]
    emitted1, last_ts, seen = select_new_hits(hits1, last_ts=0, seen=set())
    assert [h["log"] for h in emitted1] == ["a"]
    # a second record with the SAME ts arrives next poll -> emit it once
    hits2 = [_hit(5, "a"), _hit(5, "b")]
    emitted2, last_ts, seen = select_new_hits(hits2, last_ts=last_ts, seen=seen)
    assert [h["log"] for h in emitted2] == ["b"]
    assert last_ts == 5
    # third poll re-returns both -> nothing new
    emitted3, last_ts, seen = select_new_hits(hits2, last_ts=last_ts, seen=seen)
    assert emitted3 == []


# -- build_tail_sql --------------------------------------------------------


def test_build_tail_sql_default_orders_by_timestamp():
    sql = build_tail_sql(stream="syslog", sql=None)
    assert 'FROM "syslog"' in sql
    assert "_timestamp" in sql.lower()


def test_build_tail_sql_uses_explicit_sql():
    assert build_tail_sql(stream="x", sql="SELECT foo FROM bar") == "SELECT foo FROM bar"


# -- follow loop (stub client) ---------------------------------------------


class StubClient:
    """Returns scripted pages on successive search() calls; records windows."""

    def __init__(self, pages):
        self.pages = list(pages)
        self.calls: list[tuple[int, int]] = []

    async def search(self, *, sql, start_time, end_time, size, from_=0):
        self.calls.append((start_time, end_time))
        return self.pages.pop(0) if self.pages else []


async def _drain(queue: asyncio.Queue) -> list[dict]:
    out = []
    while not queue.empty():
        out.append(queue.get_nowait())
    return out


async def test_follow_single_poll_emits_hits():
    client = StubClient([[_hit(1, "a"), _hit(2, "b")]])
    q: asyncio.Queue = asyncio.Queue()
    await follow(
        client, stream="s", sql=None, since_micros=0, interval=0, size=100, queue=q, follow=False
    )
    assert [h["log"] for h in await _drain(q)] == ["a", "b"]


async def test_follow_advances_window_and_dedups_across_polls():
    client = StubClient(
        [
            [_hit(1, "a"), _hit(2, "b")],
            [_hit(2, "b"), _hit(3, "c")],  # b is a boundary dup
        ]
    )
    q: asyncio.Queue = asyncio.Queue()
    slept: list[float] = []

    async def _sleep(s):
        slept.append(s)

    await follow(
        client,
        stream="s",
        sql=None,
        since_micros=0,
        interval=0.01,
        size=100,
        queue=q,
        follow=True,
        max_polls=2,
        sleep_fn=_sleep,
    )
    assert [h["log"] for h in await _drain(q)] == ["a", "b", "c"]
    # second poll's window starts at the max ts seen in poll 1 (inclusive, for dedup)
    assert client.calls[1][0] == 2
    assert slept  # follow mode sleeps between polls


async def test_run_tail_fans_out_streams_to_a_shared_consumer():
    client = StubClient([[_hit(1, "a")], [_hit(9, "z")]])
    got: list[dict] = []
    await run_tail(
        client,
        streams=["s1", "s2"],
        sql=None,
        since_micros=0,
        interval=0,
        size=100,
        follow=False,
        on_hit=got.append,
    )
    assert {h["log"] for h in got} == {"a", "z"}
