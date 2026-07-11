"""HA keepalived layer: both nodes run keepalived, the floating VIP lives on exactly one node
(the higher-priority primary in steady state), and the real VRRP state transitions happened.

Skips cleanly in single mode (the primary/secondary fixtures skip when `enable_ha` is off).
Everything here was verified by hand during the live bring-up — see specs/ha-dns.md. Ordering
note: these run after test_failover.py (alphabetical), which restores the VIP to primary, so
"primary holds the VIP" is the expected steady state here.
"""


def _holds_vip(host, vip):
    return host.run(f"ip -4 addr show | grep -q {vip}").rc == 0


def test_keepalived_running_on_both_nodes(primary, secondary):
    assert primary.service("keepalived").is_running, "keepalived not running on primary"
    assert secondary.service("keepalived").is_running, (
        "keepalived not running on secondary"
    )


def test_vip_on_exactly_one_node(primary, secondary, vip):
    holders = [
        role
        for role, host in (("primary", primary), ("secondary", secondary))
        if _holds_vip(host, vip)
    ]
    assert holders == ["primary"] or holders == ["secondary"], (
        f"VIP {vip} must be on exactly one node, found on: {holders}"
    )


def test_primary_holds_vip_in_steady_state(primary, vip):
    # primary is priority 200 vs secondary 100, so with both healthy it holds (or preempts to) the VIP.
    assert _holds_vip(primary, vip), f"primary (MASTER) does not hold the VIP {vip}"


def test_vrrp_state_transitions_logged(primary, secondary):
    pj = primary.run("sudo journalctl -u keepalived --no-pager").stdout
    sj = secondary.run("sudo journalctl -u keepalived --no-pager").stdout
    assert "Entering MASTER STATE" in pj, (
        "primary keepalived never entered MASTER STATE"
    )
    assert "Entering BACKUP STATE" in sj, (
        "secondary keepalived never entered BACKUP STATE"
    )


def test_chk_adguard_health_script(primary):
    script = primary.file("/usr/local/sbin/chk_adguard.sh")
    assert script.exists, "chk_adguard.sh health probe missing"
    # With AdGuard answering, the real DNS-answer probe exits 0 (this is what keeps the VIP).
    assert primary.run("/usr/local/sbin/chk_adguard.sh").rc == 0, (
        "chk_adguard.sh failed while AdGuard is healthy"
    )


def test_keepalived_weight_exceeds_priority_gap(primary):
    # Regression guard for the live-found bug: the health-fail penalty MUST exceed the 200-100
    # priority gap or the VIP never fails over. -120 drops a failed master to 80 (< 100).
    conf = primary.run("sudo cat /etc/keepalived/keepalived.conf").stdout
    assert "weight -120" in conf, (
        "chk_adguard weight must be -120 (must exceed the 100-pt gap)"
    )
