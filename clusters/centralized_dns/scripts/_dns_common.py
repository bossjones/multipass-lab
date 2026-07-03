"""Shared helpers for the centralized_dns verification CLIs (stdlib-only).

Imported by `adguard_cli.py` and `unbound_cli.py`. `uv run` puts the script's directory on
`sys.path`, so a sibling `import _dns_common` resolves; the hermetic test suites import it via
`pythonpath = ["../../scripts"]`.

A cluster-local cousin of centralized_monitoring's `_obs_common.py`: resolve the live server
base URL from `tofu output -json` (or an override), resolve credentials (flag > env > default),
a `poll()` readiness helper, and a `CheckReport` accumulator that drives the `check` exit code.
Deliberately depends on nothing outside the standard library — rich/typer/httpx rendering lives
in the individual CLIs.
"""

from __future__ import annotations

import json
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

# scripts/_dns_common.py -> clusters/
CLUSTERS_ROOT = Path(__file__).resolve().parents[2]

# Check exit code (nonzero). Any nonzero means "verification failed".
CHECK_FAIL_EXIT = 2


# --- OpenTofu output resolution ----------------------------------------------


def run_tofu_output(chdir: str) -> dict:
    """Return the parsed `tofu -chdir=<chdir> output -json` document."""
    raw = subprocess.run(
        ["tofu", f"-chdir={chdir}", "output", "-json"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return json.loads(raw)


def parse_tofu_output(tofu_json: dict) -> tuple[str, set[str]]:
    """Extract (server_ipv4, enabled_flags) from a parsed `tofu output -json`."""
    ip = tofu_json["server_ipv4"]["value"]
    flags = set(tofu_json.get("enabled_flags", {}).get("value", []))
    return ip, flags


def default_chdir(cluster: str = "centralized_dns") -> str:
    """The cluster dir `tofu` should run in, resolved from this file's location."""
    return str(CLUSTERS_ROOT / cluster)


@dataclass
class Target:
    """A resolved service endpoint plus the cluster's enabled feature flags."""

    base_url: str
    ip: str | None = None
    enabled_flags: set[str] = field(default_factory=set)


def resolve_target(
    *,
    port: int,
    cluster: str = "centralized_dns",
    server_url: str | None = None,
    url_env: str | None = None,
    chdir: str | None = None,
    env: dict | None = None,
    runner: Callable[[str], dict] = run_tofu_output,
) -> Target:
    """Resolve a service base URL.

    Precedence: explicit ``server_url`` > ``$url_env`` > `tofu output` (``http://<ip>:<port>``).
    When a URL override is used, `tofu` is never invoked and ``enabled_flags`` is empty.
    """
    import os

    env = os.environ if env is None else env
    if server_url is None and url_env:
        server_url = env.get(url_env)

    if server_url:
        return Target(base_url=server_url.rstrip("/"))

    chdir = chdir or default_chdir(cluster)
    ip, flags = parse_tofu_output(runner(chdir))
    return Target(base_url=f"http://{ip}:{port}", ip=ip, enabled_flags=flags)


def resolve_credentials(
    user: str | None,
    password: str | None,
    *,
    user_env: str | None = None,
    pass_env: str | None = None,
    default_user: str,
    default_password: str,
    env: dict | None = None,
) -> tuple[str, str]:
    """Resolve (user, password) with flag > env > default precedence."""
    import os

    env = os.environ if env is None else env
    if user is None and user_env:
        user = env.get(user_env)
    if password is None and pass_env:
        password = env.get(pass_env)
    return (
        user if user is not None else default_user,
        password if password is not None else default_password,
    )


# --- readiness polling -------------------------------------------------------


def poll(
    fn: Callable[[], object],
    *,
    timeout: float = 60.0,
    interval: float = 2.0,
    catch: tuple = (),
):
    """Call ``fn`` until it returns a truthy value or ``timeout`` elapses.

    Returns the first truthy result, or the last (falsy) result on timeout. Exceptions listed
    in ``catch`` are treated as a falsy attempt.
    """
    deadline = time.monotonic() + timeout
    while True:
        try:
            res = fn()
        except catch:
            res = None
        if res:
            return res
        if time.monotonic() >= deadline:
            return res
        time.sleep(interval)


# --- check reporting ---------------------------------------------------------


@dataclass
class Check:
    name: str
    status: str  # "pass" | "fail" | "skip"
    detail: str = ""


class CheckReport:
    """Accumulates individual assertions and derives an overall pass/fail + exit code."""

    def __init__(self) -> None:
        self.checks: list[Check] = []

    def add(self, name: str, ok: bool, detail: str = "") -> None:
        self.checks.append(Check(name, "pass" if ok else "fail", detail))

    def skip(self, name: str, detail: str = "") -> None:
        self.checks.append(Check(name, "skip", detail))

    @property
    def passed(self) -> bool:
        return all(c.status != "fail" for c in self.checks)

    @property
    def exit_code(self) -> int:
        return 0 if self.passed else CHECK_FAIL_EXIT

    def to_dict(self) -> dict:
        return {
            "ok": self.passed,
            "checks": [
                {"name": c.name, "status": c.status, "detail": c.detail}
                for c in self.checks
            ],
        }


def print_json(obj) -> None:
    """Emit clean, parseable JSON to stdout (for `--json` / piping)."""
    print(json.dumps(obj, indent=2, default=str))


def parse_prometheus_metrics(text: str) -> dict[str, float]:
    """Parse a Prometheus text-exposition body into {metric_name: value}.

    Ignores HELP/TYPE comments; keeps the LAST value seen for a bare metric name (labels are
    stripped, so labelled series collapse — sufficient for liveness/`check` assertions). Values
    that don't parse as float are skipped.
    """
    out: dict[str, float] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        name = parts[0].split("{", 1)[0]
        try:
            out[name] = float(parts[1])
        except ValueError:
            continue
    return out
