"""Opt-in live integration tests against a running OpenObserve.

Runs only under ``-m integration``. Resolves the endpoint from ``$OOCTL_ENDPOINT``
or (fallback) ``tofu -chdir=<repo>/clusters/centralized_monitoring output -raw
server_ipv4``. Skips cleanly when neither is available or the server is down.

    just up centralized_monitoring         # (from repo root) bring OpenObserve up
    uv run pytest -m integration           # then run these
"""

from __future__ import annotations

import asyncio
import os
import subprocess
from pathlib import Path

import pytest

from ooctl.client import OpenObserveClient
from ooctl.tail import now_micros, run_tail

pytestmark = pytest.mark.integration

# lab defaults (see clusters/centralized_monitoring/main.tf + compose.yaml.tftpl)
LAB_USER = "admin@example.com"
LAB_PASSWORD = "Complexpass#123"
LAB_ORG = "default"


def _repo_root() -> Path:
    # tools/ooctl/tests/integration -> repo root is four parents up
    return Path(__file__).resolve().parents[3]


def _resolve_endpoint() -> str | None:
    env = os.environ.get("OOCTL_ENDPOINT")
    if env:
        return env.rstrip("/")
    cluster = _repo_root() / "clusters" / "centralized_monitoring"
    try:
        proc = subprocess.run(
            ["tofu", f"-chdir={cluster}", "output", "-raw", "server_ipv4"],
            capture_output=True,
            text=True,
            timeout=30,
            check=True,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    ip = proc.stdout.strip()
    return f"http://{ip}:5080" if ip else None


@pytest.fixture
async def client():
    endpoint = _resolve_endpoint()
    if not endpoint:
        pytest.skip("no OOCTL_ENDPOINT and no tofu server_ipv4 (cluster not up)")
    c = OpenObserveClient(
        endpoint=endpoint,
        organization=LAB_ORG,
        username=LAB_USER,
        password=LAB_PASSWORD,
        timeout=15.0,
    )
    if not await c.health():
        await c.aclose()
        pytest.skip(f"OpenObserve not healthy at {endpoint}")
    yield c
    await c.aclose()


async def test_health(client):
    assert await client.health() is True


async def test_streams_returns_a_list(client):
    streams = await client.streams()
    assert isinstance(streams, list)


async def test_search_last_day_returns_a_list(client):
    streams = await client.streams(stream_type="logs")
    if not streams:
        pytest.skip("no log streams to query yet")
    name = streams[0]["name"]
    end = now_micros()
    start = end - 24 * 3600 * 1_000_000
    hits = await client.search(
        sql=f'SELECT * FROM "{name}" ORDER BY _timestamp DESC',
        start_time=start,
        end_time=end,
        size=5,
    )
    assert isinstance(hits, list)


async def test_follow_smoke_runs_without_error(client):
    streams = await client.streams(stream_type="logs")
    if not streams:
        pytest.skip("no log streams to tail yet")
    name = streams[0]["name"]
    collected: list[dict] = []
    # two quick polls over the last 5 minutes; asserts the follow loop drives the
    # live API end-to-end (hit count is not guaranteed on an idle cluster).
    await asyncio.wait_for(
        run_tail(
            client,
            streams=[name],
            sql=None,
            since_micros=now_micros() - 5 * 60 * 1_000_000,
            interval=0.5,
            size=50,
            follow=True,
            on_hit=collected.append,
            max_polls=2,
        ),
        timeout=30,
    )
    assert isinstance(collected, list)
