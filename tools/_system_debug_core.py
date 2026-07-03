"""Pure, stdlib-only core for system_debug — parsing, analysis, and policy.

Split out from the `system_debug.py` CLI the same way `_dns_common.py` is split from the
centralized_dns CLIs: everything here is deterministic and side-effect-free (no ssh, no tofu,
no rich/typer), so the hermetic suite in `tools/tests/` can drive it without any VMs. The CLI
owns the I/O (subprocess to ssh/tofu) and the rich rendering.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

# Exit codes (also the CLI's process exit codes).
EXIT_OK = 0
EXIT_ISSUES = 2
EXIT_UNREACHABLE = 3
EXIT_USAGE = 4

# Units always swept, on top of any `systemctl --failed` unit discovered on the box.
BASE_UNITS = ["otelcol-contrib", "cloud-final.service"]

# Strong failure signatures — used both to highlight lines and to decide health. Kept specific
# (not bare "error"/"warning") so a clean boot with benign warnings still reports healthy.
SIGNATURES = [
    "permission denied",
    "failed to",
    "failed with",
    "cannot open",
    "cannot access",
    "no such file",
    "connection refused",
    "connection reset",
    "timed out",
    "operation not permitted",
    "address already in use",
    "oom",
    "out of memory",
    "manifest unknown",
    "error pulling",
    "pull access denied",
    "no route to host",
    "x509",
    "fatal",
    "segfault",
    "core dump",
]

_UNIT_RE = re.compile(r"^[\w.@:-]+$")


@dataclass
class TargetResult:
    role: str
    name: str
    ip: str
    reachable: bool = False
    error: str = ""
    cloud_init_status: str = "unknown"
    failed_units: list[str] = field(default_factory=list)
    activating_units: list[str] = field(default_factory=list)
    signature_hits: list[tuple[str, str]] = field(default_factory=list)  # (source, line)

    @property
    def healthy(self) -> bool:
        return (
            self.reachable
            and self.cloud_init_status == "done"
            and not self.failed_units
            and not self.signature_hits
        )

    def to_json(self) -> dict[str, object]:
        return {
            "role": self.role,
            "name": self.name,
            "ip": self.ip,
            "reachable": self.reachable,
            "cloud_init_status": self.cloud_init_status,
            "failed_units": self.failed_units,
            "activating_units": self.activating_units,
            "signature_hits": [{"source": s, "line": ln} for s, ln in self.signature_hits],
            "healthy": self.healthy,
        }


def sanitize_units(units: list[str]) -> list[str]:
    """Keep only well-formed systemd unit names — nothing that could reach the remote shell."""
    return [u for u in units if _UNIT_RE.match(u)]


def build_remote_script(extra_units: list[str]) -> str:
    """A single bash blob (run via `sudo bash -s`) that dumps delimited diagnostic sections.

    It discovers `--failed` units on the box itself, so one SSH round-trip covers the whole sweep.
    """
    extras = " ".join(sanitize_units(extra_units))
    return f"""
set +e
echo '===CLOUDINIT==='
cloud-init status --long 2>&1 || true
echo '===FAILED==='
systemctl --failed --no-legend --plain 2>/dev/null || true
echo '===ACTIVATING==='
systemctl list-units --state=activating --no-legend --plain 2>/dev/null || true
echo '===ERRSWEEP==='
journalctl -b -p err --no-pager -n 60 2>/dev/null || true
BASE="{' '.join(BASE_UNITS)} {extras}"
FAILED=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{{print $1}}')
ALL=$(printf '%s\\n' $BASE $FAILED | awk 'NF && !seen[$0]++')
for u in $ALL; do
  echo "===UNIT $u==="
  journalctl -u "$u" -b -p warning..emerg --no-pager -n 40 2>/dev/null || true
done
echo '===END==='
""".strip()


def parse_sections(out: str) -> dict[str, list[str]]:
    """Split the delimited remote output into {marker: [lines]} (marker sans the ``===``)."""
    sections: dict[str, list[str]] = {}
    current = "PREAMBLE"
    for line in out.splitlines():
        if line.startswith("===") and line.endswith("===") and len(line) > 6:
            current = line.strip("=").strip()
            sections.setdefault(current, [])
            continue
        sections.setdefault(current, []).append(line)
    return sections


def match_signatures(lines: list[str]) -> list[str]:
    """Return the (stripped) lines that contain any strong failure signature."""
    hits: list[str] = []
    for line in lines:
        low = line.lower()
        if any(sig in low for sig in SIGNATURES):
            hits.append(line.strip())
    return hits


def analyze(role: str, host: dict[str, str], out: str) -> TargetResult:
    """Turn one target's raw remote output into a structured, health-scored result."""
    res = TargetResult(
        role=role, name=host.get("name", role), ip=host.get("ipv4", "?"), reachable=True
    )
    sections = parse_sections(out)

    for line in sections.get("CLOUDINIT", []):
        s = line.strip().lower()
        if s.startswith("status:"):
            res.cloud_init_status = s.split(":", 1)[1].strip() or "unknown"
            break

    res.failed_units = [ln.split()[0] for ln in sections.get("FAILED", []) if ln.strip()]
    res.activating_units = [ln.split()[0] for ln in sections.get("ACTIVATING", []) if ln.strip()]

    seen: set[tuple[str, str]] = set()
    for marker, lines in sections.items():
        if marker == "ERRSWEEP":
            source = "err-sweep"
        elif marker.startswith("UNIT "):
            source = marker[len("UNIT "):]
        else:
            continue
        for line in match_signatures(lines):
            pair = (source, line)
            if pair not in seen:
                seen.add(pair)
                res.signature_hits.append(pair)
    return res


def backoff_delay(attempt: int, base: float) -> float:
    """Exponential backoff: base, base*3, base*9, … (attempt is 1-indexed)."""
    return base * (3 ** (attempt - 1))


def choose_exit_code(results: list[TargetResult]) -> int:
    """0 all healthy · 2 reachable-but-broken · 3 nothing answered."""
    if all(r.healthy for r in results):
        return EXIT_OK
    reachable = [r for r in results if r.reachable]
    if any(
        r.signature_hits or r.failed_units or r.cloud_init_status not in ("done", "unknown")
        for r in reachable
    ):
        return EXIT_ISSUES
    if not reachable:
        return EXIT_UNREACHABLE
    return EXIT_ISSUES
