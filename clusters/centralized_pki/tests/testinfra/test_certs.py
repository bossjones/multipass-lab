"""PKI end-to-end: the cert Traefik serves is issued by, and chains to, step-ca.

Default (internal) mode only — skipped when enable_letsencrypt_staging is on, where the leaf
chains to Let's Encrypt staging instead of the step-ca root.
"""

import time

import pytest


def _wait(fn, timeout=180, interval=5):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        last = fn()
        if last:
            return last
        time.sleep(interval)
    return last


@pytest.fixture
def _internal_only(enabled_flags):
    if "enable_letsencrypt_staging" in enabled_flags:
        pytest.skip("LE staging mode: leaf chains to LE staging, not the step-ca root")


def _served_leaf_issuer(services, domain):
    res = services.run(
        "echo | openssl s_client -connect localhost:443 "
        f"-servername warden.{domain}2>/dev/null | openssl x509 -noout -issuer"
    )
    return res.stdout.strip() if res.rc == 0 else ""


def test_served_leaf_issued_by_step_ca(_internal_only, services, domain):
    issuer = _wait(lambda: _served_leaf_issuer(services, domain) or None)
    assert issuer, "could not read the served leaf's issuer"
    # step-ca's intermediate CN carries the CA name (DOCKER_STEPCA_INIT_NAME = centralized-pki-ca).
    assert "centralized-pki" in issuer.lower(), f"unexpected issuer: {issuer}"


def test_served_leaf_chains_to_step_ca_root(_internal_only, services, domain):
    # Let openssl verify the FULL served chain (leaf + step-ca intermediate) against the fetched
    # root. `-verify_return_error` makes a bad chain a nonzero exit; "Verify return code: 0" confirms.
    verify = (
        "echo | openssl s_client -connect localhost:443 "
        f"-servername warden.{domain}"
        "-CAfile /opt/stack/traefik/certs/root_ca.crt -verify_return_error 2>&1 "
        "| grep -q 'Verify return code: 0 (ok)'"
    )
    got = _wait(lambda: services.run(verify).rc == 0)
    assert got, "served leaf does not verify against the step-ca root"
