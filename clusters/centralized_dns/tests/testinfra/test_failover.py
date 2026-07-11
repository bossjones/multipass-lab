"""HA failover: stopping AdGuard on the VIP holder moves the VIP to the peer (DNS keeps
answering from the Mac host), and once AdGuard recovers the VIP preempts back to primary.

This mirrors `just dns-failover-test` but as an assertable pytest. It mutates cluster state
(stops/starts AdGuard) and restores it in a finally-block; it is ordered before the other HA
suites (alphabetical: failover < keepalived < sync) so it leaves the VIP back on primary for them.
`dig @VIP` is run from the host (the real client path proven in the Task-1 spike). Skips cleanly
in single mode. See specs/ha-dns.md.
"""

import subprocess
import time

import pytest

# chk_adguard fall 2 * interval 2 (~4s) + VRRP transition, plus per-iteration SSH poll latency.
FAILOVER_WINDOW = 15
PREEMPT_WINDOW = 20


def _dig_vip(vip):
    """Resolve example.com against the VIP from the host — returns True if it answers."""
    r = subprocess.run(
        ["dig", f"@{vip}", "example.com", "+short", "+time=1", "+tries=1"],
        capture_output=True,
        text=True,
    )
    return r.returncode == 0 and bool(r.stdout.strip())


def _holds_vip(host, vip):
    return host.run(f"ip -4 addr show | grep -q {vip}").rc == 0


def test_failover_and_preempt_back(primary, secondary, vip):
    assert vip, "vip_address is empty — not HA?"
    assert _dig_vip(vip), "VIP did not answer DNS before the test started"

    if _holds_vip(primary, vip):
        holder, holder_host, other, other_host = (
            "primary",
            primary,
            "secondary",
            secondary,
        )
    elif _holds_vip(secondary, vip):
        holder, holder_host, other, other_host = (
            "secondary",
            secondary,
            "primary",
            primary,
        )
    else:
        pytest.fail(f"no node holds the VIP {vip} before the test")

    try:
        holder_host.run("sudo systemctl stop AdGuardHome")
        # a failing chk_adguard must drop the holder below the peer so the VIP actually migrates
        moved = False
        for _ in range(FAILOVER_WINDOW):
            if _holds_vip(other_host, vip) and _dig_vip(vip):
                moved = True
                break
            time.sleep(1)
        assert moved, (
            f"VIP {vip} did not migrate to {other} / stopped answering within "
            f"{FAILOVER_WINDOW}s of stopping AdGuard on {holder}"
        )
    finally:
        holder_host.run("sudo systemctl start AdGuardHome")

    # primary is the higher-priority node: once healthy the VIP must return to it, still answering
    back = False
    for _ in range(PREEMPT_WINDOW):
        if _holds_vip(primary, vip) and _dig_vip(vip):
            back = True
            break
        time.sleep(1)
    assert back, f"VIP {vip} did not preempt back to primary within {PREEMPT_WINDOW}s"
