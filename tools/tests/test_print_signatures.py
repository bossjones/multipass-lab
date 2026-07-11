"""Hermetic test for print_signatures.py (no VMs, no ssh, no tofu).

Run: uv run --with pytest pytest tools/tests/test_print_signatures.py

print_signatures.py has no pure logic to extract into _system_debug_core-style unit tests —
its entire behavior is "print SIGNATURES joined with |" — so this exercises it the same way
it's actually invoked (`uv run tools/print_signatures.py`), via subprocess.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import _system_debug_core as core  # noqa: E402

SCRIPT = Path(__file__).resolve().parents[1] / "print_signatures.py"


def _run() -> str:
    result = subprocess.run(
        [sys.executable, str(SCRIPT)], capture_output=True, text=True, check=True
    )
    return result.stdout.strip()


def test_prints_signatures_joined_with_pipe():
    assert _run() == "|".join(core.SIGNATURES)


def test_output_is_a_valid_grep_alternation():
    # Must compile as a regex (what `grep -iE` requires) and match each signature verbatim.
    pattern = re.compile(_run(), re.IGNORECASE)
    for signature in core.SIGNATURES:
        assert pattern.search(f"some log line containing {signature} in it")


def test_output_does_not_match_benign_log_lines():
    pattern = re.compile(_run(), re.IGNORECASE)
    assert not pattern.search("Started otelcol-contrib.service")
