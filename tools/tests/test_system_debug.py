"""Hermetic tests for the system_debug pure core (no VMs, no ssh, no tofu).

Run: uv run --with pytest pytest tools/tests/test_system_debug.py
The core is stdlib-only, so pytest alone is enough — no typer/rich needed.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

# tools/tests/ -> tools/ on the path so `import _system_debug_core` resolves.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import _system_debug_core as core  # noqa: E402


# --- backoff ------------------------------------------------------------------


@pytest.mark.parametrize(
    "attempt,base,expected",
    [(1, 5.0, 5.0), (2, 5.0, 15.0), (3, 5.0, 45.0), (1, 10.0, 10.0), (2, 10.0, 30.0)],
)
def test_backoff_delay_is_exponential_base_times_3(attempt, base, expected):
    assert core.backoff_delay(attempt, base) == expected


# --- unit sanitization --------------------------------------------------------


def test_sanitize_units_keeps_valid_unit_names():
    got = core.sanitize_units(["syslog-ng", "otelcol-contrib", "netbox-stack.service", "foo@bar"])
    assert got == ["syslog-ng", "otelcol-contrib", "netbox-stack.service", "foo@bar"]


def test_sanitize_units_drops_shell_metacharacters():
    # A name with a space or `;` must never reach the remote shell.
    assert core.sanitize_units(["ok-unit", "bad; rm -rf /", "with space"]) == ["ok-unit"]


# --- remote script ------------------------------------------------------------


def test_build_remote_script_includes_core_probes():
    script = core.build_remote_script([])
    assert "cloud-init status --long" in script
    assert "systemctl --failed" in script
    assert "journalctl -b -p err" in script
    # base units must be swept
    assert "otelcol-contrib" in script


def test_build_remote_script_includes_valid_extra_unit_and_drops_invalid():
    script = core.build_remote_script(["syslog-ng", "bad; boom"])
    assert "syslog-ng" in script
    assert "boom" not in script


# --- section parsing ----------------------------------------------------------


SAMPLE = """\
===CLOUDINIT===
status: done
extended_status: done
===FAILED===
===ERRSWEEP===
Jul 03 18:10:45 host otelcol-contrib[48359]: error open /var/log/syslog: permission denied
===UNIT otelcol-contrib===
Jul 03 18:10:45 host otelcol-contrib[48359]: Failed to open file
===END===
"""


def test_parse_sections_splits_on_markers():
    sections = core.parse_sections(SAMPLE)
    assert sections["CLOUDINIT"][0] == "status: done"
    assert "UNIT otelcol-contrib" in sections
    assert sections["FAILED"] == []


def test_match_signatures_flags_permission_denied():
    hits = core.match_signatures(["all good", "open /var/log/syslog: permission denied"])
    assert hits == ["open /var/log/syslog: permission denied"]


def test_match_signatures_ignores_clean_lines():
    assert core.match_signatures(["started fine", "listening on :4318"]) == []


# --- analyze ------------------------------------------------------------------


def _host():
    return {"name": "centralized-pki-services", "ipv4": "10.0.0.5"}


def test_analyze_healthy_when_done_and_clean():
    out = "===CLOUDINIT===\nstatus: done\n===FAILED===\n===ERRSWEEP===\n===END===\n"
    res = core.analyze("services", _host(), out)
    assert res.cloud_init_status == "done"
    assert res.failed_units == []
    assert res.signature_hits == []
    assert res.healthy is True


def test_analyze_surfaces_otelcol_permission_denied():
    res = core.analyze("services", _host(), SAMPLE)
    assert res.healthy is False
    # the smoking-gun line is captured with its source unit
    sources = {src for src, _ in res.signature_hits}
    assert "otelcol-contrib" in sources
    assert any("permission denied" in line for _, line in res.signature_hits)


def test_analyze_parses_failed_units():
    out = (
        "===CLOUDINIT===\nstatus: done\n"
        "===FAILED===\nnetbox-stack.service loaded failed failed NetBox\n"
        "===ERRSWEEP===\n===END===\n"
    )
    res = core.analyze("server", _host(), out)
    assert res.failed_units == ["netbox-stack.service"]
    assert res.healthy is False


def test_analyze_unhealthy_while_cloud_init_still_running():
    out = "===CLOUDINIT===\nstatus: running\n===FAILED===\n===ERRSWEEP===\n===END===\n"
    res = core.analyze("services", _host(), out)
    assert res.cloud_init_status == "running"
    assert res.healthy is False


def test_target_result_to_json_round_trips():
    res = core.analyze("services", _host(), SAMPLE)
    data = res.to_json()
    assert data["role"] == "services"
    assert data["ip"] == "10.0.0.5"
    assert data["healthy"] is False
    assert isinstance(data["signature_hits"], list)


# --- exit-code policy ---------------------------------------------------------


def _result(**kw):
    base = dict(role="r", name="n", ip="1.2.3.4", reachable=True, cloud_init_status="done")
    base.update(kw)
    return core.TargetResult(**base)


def test_choose_exit_code_ok_when_all_healthy():
    assert core.choose_exit_code([_result()]) == core.EXIT_OK


def test_choose_exit_code_issues_when_reachable_with_hits():
    r = _result(signature_hits=[("otelcol-contrib", "permission denied")])
    assert core.choose_exit_code([r]) == core.EXIT_ISSUES


def test_choose_exit_code_unreachable_when_no_target_answered():
    r = _result(reachable=False, error="ssh timed out", cloud_init_status="unknown")
    assert core.choose_exit_code([r]) == core.EXIT_UNREACHABLE
