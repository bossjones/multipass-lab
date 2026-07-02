"""Shared helpers for the PKI verification CLIs (stdlib-only).

Imported by `stepca_cli.py`, `authelia_cli.py`, `vaultwarden_cli.py`, and `tls_cli.py`.
`uv run` puts the script's directory on `sys.path`, so a sibling `import _pki_common`
resolves; the hermetic test suites import it via `pythonpath = ["../../scripts"]`.

Forked from clusters/centralized_monitoring/scripts/_obs_common.py. Differences:
  * `parse_tofu_output` reads ca_ipv4/services_ipv4/enabled_flags/domain (this cluster's
    outputs), and `resolve_target(role=...)` resolves either VM,
  * `http_get_json` gains a `ca_cert` for verifying against step-ca's root,
  * TLS chain helpers (`fetch_leaf_cert_pem`, `verify_chains_to`) so tls_cli can assert a
    served leaf chains to the expected root.

Deliberately depends on nothing outside the standard library — rich/typer/httpx/cryptography
rendering lives in the individual CLIs.
"""

from __future__ import annotations

import base64
import json
import socket
import ssl
import subprocess
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

# scripts/_pki_common.py -> clusters/
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


def parse_tofu_output(tofu_json: dict) -> dict:
    """Extract {ca_ipv4, services_ipv4, enabled_flags, domain} from `tofu output -json`."""
    return {
        "ca_ipv4": tofu_json.get("ca_ipv4", {}).get("value"),
        "services_ipv4": tofu_json.get("services_ipv4", {}).get("value"),
        "enabled_flags": set(tofu_json.get("enabled_flags", {}).get("value", [])),
        "domain": tofu_json.get("domain", {}).get("value", ""),
    }


def default_chdir(cluster: str) -> str:
    """The cluster dir `tofu` should run in, resolved from this file's location."""
    return str(CLUSTERS_ROOT / cluster)


@dataclass
class Target:
    """A resolved service endpoint plus the cluster's enabled feature flags + domain."""

    base_url: str
    ip: str | None = None
    enabled_flags: set[str] = field(default_factory=set)
    domain: str = ""


def resolve_target(
    *,
    role: str,
    port: int,
    scheme: str = "https",
    cluster: str = "centralized_pki",
    server_url: str | None = None,
    url_env: str | None = None,
    chdir: str | None = None,
    env: dict | None = None,
    runner: Callable[[str], dict] = run_tofu_output,
) -> Target:
    """Resolve a service base URL for the given role ("ca" | "services").

    Precedence: explicit ``server_url`` > ``$url_env`` > `tofu output`
    (``<scheme>://<ip>:<port>``). When a URL override is used, `tofu` is never invoked
    and ``enabled_flags``/``domain`` are empty.
    """
    import os

    env = os.environ if env is None else env
    if server_url is None and url_env:
        server_url = env.get(url_env)

    if server_url:
        return Target(base_url=server_url.rstrip("/"))

    chdir = chdir or default_chdir(cluster)
    data = parse_tofu_output(runner(chdir))
    ip = data["ca_ipv4"] if role == "ca" else data["services_ipv4"]
    return Target(
        base_url=f"{scheme}://{ip}:{port}",
        ip=ip,
        enabled_flags=data["enabled_flags"],
        domain=data["domain"],
    )


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


# --- stdlib HTTP -------------------------------------------------------------


class HttpError(Exception):
    """A non-2xx response or a transport failure. ``status`` is 0 for transport errors."""

    def __init__(self, status: int, message: str = ""):
        super().__init__(
            f"HTTP {status}: {message}" if status else f"connection error: {message}"
        )
        self.status = status


def http_get_json(
    url: str,
    *,
    auth: tuple[str, str] | None = None,
    timeout: float = 10.0,
    headers: dict | None = None,
    insecure: bool = False,
    ca_cert: str | None = None,
):
    """GET ``url`` and parse JSON. Raises :class:`HttpError` on non-2xx / transport error.

    ``ca_cert`` verifies HTTPS against a specific root (step-ca); ``insecure`` skips
    verification entirely. ``ca_cert`` wins over ``insecure``.
    """
    req = urllib.request.Request(url, method="GET")
    for key, value in (headers or {}).items():
        req.add_header(key, value)
    if auth:
        token = base64.b64encode(f"{auth[0]}:{auth[1]}".encode()).decode()
        req.add_header("Authorization", f"Basic {token}")
    if ca_cert:
        ctx = ssl.create_default_context(cafile=ca_cert)
    elif insecure:
        ctx = ssl._create_unverified_context()
    else:
        ctx = None
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            body = resp.read().decode()
    except urllib.error.HTTPError as exc:
        raise HttpError(exc.code, exc.reason) from exc
    except urllib.error.URLError as exc:
        raise HttpError(0, str(exc.reason)) from exc
    return json.loads(body) if body else None


# --- TLS chain inspection (stdlib ssl/socket) --------------------------------


def fetch_leaf_cert_pem(host: str, port: int = 443, *, server_hostname: str | None = None, timeout: float = 10.0) -> str:
    """Return the PEM of the leaf cert served at host:port, WITHOUT verifying it.

    Used to inspect a cert whose chain we don't (yet) trust — e.g. reading the issuer of a
    Traefik-served leaf. Raises OSError/ssl.SSLError on connect failure.
    """
    ctx = ssl._create_unverified_context()
    with socket.create_connection((host, port), timeout=timeout) as sock:
        with ctx.wrap_socket(sock, server_hostname=server_hostname or host) as ssock:
            der = ssock.getpeercert(binary_form=True)
    return ssl.DER_cert_to_PEM_cert(der)


def verify_chains_to(
    host: str,
    port: int,
    ca_cert: str,
    *,
    server_hostname: str | None = None,
    check_hostname: bool = False,
    timeout: float = 10.0,
) -> tuple[bool, str]:
    """Return (ok, detail): does the leaf served at host:port chain to ``ca_cert``?

    ``check_hostname`` is off by default because lab certs are commonly validated by IP.
    A successful TLS handshake with ``cafile=ca_cert`` proves the chain terminates at that root.
    """
    ctx = ssl.create_default_context(cafile=ca_cert)
    ctx.check_hostname = check_hostname
    if not check_hostname:
        ctx.verify_mode = ssl.CERT_REQUIRED  # still verify the chain, just not the hostname
    try:
        with socket.create_connection((host, port), timeout=timeout) as sock:
            with ctx.wrap_socket(sock, server_hostname=server_hostname or host):
                return True, "chain verified"
    except ssl.SSLCertVerificationError as exc:
        return False, f"verify failed: {exc.verify_message or exc}"
    except (ssl.SSLError, OSError) as exc:
        return False, f"connection error: {exc}"


# --- readiness polling -------------------------------------------------------


def poll(
    fn: Callable[[], object],
    *,
    timeout: float = 60.0,
    interval: float = 2.0,
    catch: tuple = (),
):
    """Call ``fn`` until it returns a truthy value or ``timeout`` elapses."""
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


# --- output ------------------------------------------------------------------


def print_json(obj) -> None:
    """Emit clean, parseable JSON to stdout (for `--json` / piping)."""
    print(json.dumps(obj, indent=2, default=str))
