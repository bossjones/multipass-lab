"""Live checks for Heimdall tile management. Runs only under `just verify`.

Gated on `enable_heimdall`. Two checks:
  1. Auto-seed (the default path): after `just up` — which blocks on cloud-init —
     the dashboard is already populated, proving the cloud-init `seed` step ran.
     No manual sync.
  2. The laptop CLI round-trip (generate -> sync -> list) over ssh + docker cp.
"""

import os
import subprocess
import tempfile
import time
from pathlib import Path

import pytest

# tests/testinfra/ -> clusters/centralized_monitoring/
CLUSTER_DIR = Path(__file__).resolve().parents[2]
CLI = CLUSTER_DIR / "scripts" / "heimdall_cli.py"

# Always-on spine tiles that seeding must produce regardless of optional flags.
EXPECTED_TILES = {"Grafana", "Prometheus", "Alertmanager"}


def _cli(*args):
    """Run the heimdall CLI (uv single-file) against this cluster, return stdout."""
    result = subprocess.run(
        ["uv", "run", str(CLI), *args, "--chdir", str(CLUSTER_DIR)],
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout


@pytest.fixture
def heimdall_enabled(enabled_exporters):
    if "enable_heimdall" not in enabled_exporters:
        pytest.skip("enable_heimdall disabled")


def test_cloud_init_autoseed_populates_dashboard(heimdall_enabled, server):
    """After bring-up, tiles already exist with NO manual sync (cloud-init seeded).

    The cloud-init seed is best-effort and may lag the SSH-reachable moment, so
    poll briefly. Assumes the default `enable_heimdall_seed=true`.
    """
    deadline = time.time() + 120
    listed = ""
    while time.time() < deadline:
        listed = _cli("list")  # remote list — no sync first
        if all(t in listed for t in EXPECTED_TILES):
            break
        time.sleep(5)
    missing = {t for t in EXPECTED_TILES if t not in listed}
    assert not missing, f"auto-seed did not populate Heimdall: missing {missing}\n{listed}"


def test_generate_sync_list_roundtrip(heimdall_enabled, server):
    """generate -> sync --prune -> list lands the spine tiles in live Heimdall."""
    config = tempfile.NamedTemporaryFile(suffix=".yaml", delete=False).name
    try:
        _cli("generate", "-o", config)
        _cli("sync", "--config", config, "--prune")
    finally:
        os.unlink(config)

    listed = _cli("list")
    missing = {t for t in EXPECTED_TILES if t not in listed}
    assert not missing, f"tiles missing from Heimdall after sync: {missing}\n{listed}"
