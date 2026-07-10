#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""print_signatures — emit `_system_debug_core.SIGNATURES` as one `grep -iE` alternation.

Lets a live background journal tail (started before provisioning, per specs/ha-dns.md and
specs/pki-and-dns.md) grep for the same strong failure signatures `system_debug.py` already
uses for health scoring, instead of a second hand-copied list drifting out of sync.

    grep -iE "$(uv run tools/print_signatures.py)" scratchpad/*.log
"""

from __future__ import annotations

import _system_debug_core as core

if __name__ == "__main__":
    print("|".join(core.SIGNATURES))
