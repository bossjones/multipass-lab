"""HA AdGuardHome-Sync layer: the sync unit runs on primary ONLY (unidirectional
primary -> secondary), its journal shows a successful replication cycle, and a rewrite added on
primary actually shows up on secondary after a sync.

Config edits must only ever hit primary (secondary is overwritten each cycle) — so the rewrite
round-trip below adds on primary's own IP via the CLI's default target (dns_rewrite_target =
primary), triggers a sync, and reads it back from secondary via `--node secondary`. It cleans up
after itself. Skips cleanly in single mode. See specs/ha-dns.md.
"""

import subprocess
import time
from pathlib import Path

# tests/testinfra/ -> clusters/centralized_dns/ -> <repo root>
CLUSTER_DIR = Path(__file__).resolve().parents[2]
CLUSTER_NAME = CLUSTER_DIR.name
REPO_ROOT = CLUSTER_DIR.parents[1]
CLI = CLUSTER_DIR / "scripts" / "adguard_cli.py"

TEST_DOMAIN = "sync-testinfra.lab"
TEST_ANSWER = "10.55.55.55"


def _cli(*args):
    """Run adguard_cli.py from the repo root (its tofu resolution is repo-root relative)."""
    return subprocess.run(
        ["uv", "run", str(CLI), "--cluster", CLUSTER_NAME, *args],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )


def test_sync_service_active_on_primary(primary):
    assert primary.service("adguardhome-sync").is_running, (
        "adguardhome-sync not running on primary"
    )


def test_sync_service_absent_on_secondary(secondary):
    # Unidirectional: only the origin (primary) runs the sync unit. secondary must NOT.
    assert not secondary.service("adguardhome-sync").is_running, (
        "adguardhome-sync must not run on secondary (it is the replica)"
    )


def test_sync_journal_shows_successful_cycle(primary, secondary_ip):
    journal = primary.run("sudo journalctl -u adguardhome-sync --no-pager").stdout
    assert "Sync done" in journal, "adguardhome-sync never logged a completed sync"
    assert secondary_ip in journal, (
        f"sync journal never referenced the replica {secondary_ip}"
    )


def test_rewrite_replicates_primary_to_secondary(primary, secondary_ip):
    # add on primary (CLI default target = dns_rewrite_target = primary), never the VIP/secondary
    add = _cli("rewrite-set", TEST_DOMAIN, TEST_ANSWER)
    assert add.returncode == 0, (
        f"rewrite-set on primary failed: {add.stderr or add.stdout}"
    )
    try:
        # trigger an immediate sync (the unit runs cron @every sync_interval; runOnStart on restart)
        primary.run("sudo systemctl restart adguardhome-sync")
        replicated = False
        for _ in range(15):
            lst = _cli("--node", "secondary", "rewrite-list")
            if lst.returncode == 0 and TEST_DOMAIN in lst.stdout:
                replicated = True
                break
            time.sleep(1)
        assert replicated, (
            f"{TEST_DOMAIN} did not replicate to secondary ({secondary_ip}) within 15s"
        )
    finally:
        # clean up on primary and re-sync so secondary drops it too
        _cli("rewrite-delete", TEST_DOMAIN, TEST_ANSWER)
        primary.run("sudo systemctl restart adguardhome-sync")
