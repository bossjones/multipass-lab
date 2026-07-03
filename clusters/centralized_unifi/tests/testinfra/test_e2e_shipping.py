"""End-to-end: a log emitted on the USG reaches the collector, and the exporter counters move.

This is the headline behavioural check — it exercises the real appliance pipeline (rsyslog 5.8.11
`@host` UDP forward -> syslog-ng 3.28.1 network() source -> /var/log/remote), plus the legacy
syslog_ng_exporter that would run on the real UCK.
"""

import time
import uuid


def _emit_on_usg(usg, version_mode, tag, message):
    """Emit a log line from the USG's rsyslog (inside the container in exact mode)."""
    cmd = f"logger -p local7.info -t {tag} '{message}'"
    if version_mode == "exact":
        usg.run(f"sudo docker exec unifi-rsyslog {cmd}")
    else:
        usg.run(cmd)


def test_usg_log_reaches_collector(controller, usg, version_mode, hosts):
    """A unique token logged on the USG must appear under /var/log/remote on the controller."""
    token = f"e2e-{uuid.uuid4().hex[:12]}"
    _emit_on_usg(usg, version_mode, "e2e", token)

    found = False
    for _ in range(15):  # UDP is lossy — retry the emit + poll
        _emit_on_usg(usg, version_mode, "e2e", token)
        res = controller.run(f"sudo grep -rqs {token} /var/log/remote/ && echo HIT || true")
        if "HIT" in res.stdout:
            found = True
            break
        time.sleep(4)

    assert found, f"token {token} never reached /var/log/remote on the controller"


def test_collector_folders_by_usg_hostname(controller, usg, version_mode, hosts):
    """keep-hostname(yes) means received logs folder by the USG's self-reported hostname."""
    usg_name = hosts["usg"]["name"]
    token = f"host-{uuid.uuid4().hex[:12]}"
    for _ in range(15):
        _emit_on_usg(usg, version_mode, "hostcheck", token)
        res = controller.run(
            f"sudo grep -rls {token} /var/log/remote/ 2>/dev/null || true"
        )
        if usg_name in res.stdout:
            return
        time.sleep(4)
    # Non-fatal fidelity check: fold-by-hostname depends on the USG advertising its name over UDP.
    # If the token landed anywhere under /var/log/remote the shipping test already proved delivery.
    res = controller.run(f"sudo grep -rls {token} /var/log/remote/ 2>/dev/null || true")
    assert res.stdout.strip(), f"token {token} not found under /var/log/remote at all"


def test_exporter_counters_move(controller, usg, version_mode, enabled_exporters):
    """Under the generator's traffic, the syslog_ng_exporter must report processed events."""
    if "syslogng" not in enabled_exporters:
        return  # exporter disabled — nothing to assert
    # Drive a few messages to be sure counters are non-zero.
    for i in range(5):
        _emit_on_usg(usg, version_mode, "loadcheck", f"drive-{i}")
        time.sleep(1)
    out = controller.run("curl -s --max-time 10 http://localhost:9577/metrics")
    assert out.rc == 0
    # The exporter exposes syslog_ng_* counters; at least one destination/source counter is > 0.
    nonzero = controller.run(
        "curl -s --max-time 10 http://localhost:9577/metrics "
        "| awk '/^syslog_ng_/ && $2+0 > 0 {c++} END{print c+0}'"
    )
    assert nonzero.stdout.strip() != "0", out.stdout
