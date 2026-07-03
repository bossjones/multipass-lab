"""Fixtures for the hermetic macos_trust_cli suite.

No VMs, no real keychain: a self-signed root PEM stands in for the internal CA, a temp dir mimics
the Firefox Profiles tree, and stub `security`/`certutil` binaries on PATH let us exercise real
execution without touching the host trust store.
"""

from __future__ import annotations

import datetime
import os
import stat

import pytest


@pytest.fixture
def ca_pem_file(tmp_path):
    """A self-signed root cert (CN 'lab internal CA test') written to a temp .crt; returns its path."""
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.x509.oid import NameOID

    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "lab internal CA test")])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(days=1))
        .not_valid_after(now + datetime.timedelta(days=3650))
        .add_extension(x509.BasicConstraints(ca=True, path_length=1), critical=True)
        .sign(key, hashes.SHA256())
    )
    path = tmp_path / "root_ca.crt"
    path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    return str(path)


@pytest.fixture
def firefox_dir(tmp_path):
    """A Firefox Profiles dir with two profile subdirs; returns its path."""
    base = tmp_path / "firefox_profiles"
    for prof in ("abc.default", "xyz.dev-edition"):
        (base / prof).mkdir(parents=True)
    return str(base)


@pytest.fixture
def empty_firefox_dir(tmp_path):
    """A Firefox Profiles path that does not exist (Firefox not installed)."""
    return str(tmp_path / "no_firefox")


@pytest.fixture
def fake_bins(tmp_path, monkeypatch):
    """Put stub `security` and `certutil` on PATH. Returns a helper to (re)write them with an exit code."""
    bindir = tmp_path / "bin"
    bindir.mkdir()

    def _write(name: str, exit_code: int = 0):
        p = bindir / name
        p.write_text(f'#!/usr/bin/env bash\necho "stub {name} $@"\nexit {exit_code}\n')
        p.chmod(p.stat().st_mode | stat.S_IEXEC | stat.S_IRWXU)

    _write("security")
    _write("certutil")
    # `sudo` stub: just exec the rest (so `sudo security ...` runs our stub security).
    sudo = bindir / "sudo"
    sudo.write_text('#!/usr/bin/env bash\nexec "$@"\n')
    sudo.chmod(sudo.stat().st_mode | stat.S_IEXEC | stat.S_IRWXU)

    monkeypatch.setenv("PATH", f"{bindir}{os.pathsep}{os.environ['PATH']}")
    return _write
