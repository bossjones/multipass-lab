"""Hermetic behavior tests for macos_trust_cli.

Drives the CLI via CliRunner with a self-signed root (--ca-cert, no network), a temp Firefox
Profiles tree, and stub security/certutil binaries — so real execution is exercised without ever
touching the host keychain. See specs/internal-ca.md.
"""

import macos_trust_cli as mt
from typer.testing import CliRunner

runner = CliRunner()


def _run(*args):
    return runner.invoke(mt.app, list(args))


# ---- install (dry-run: no execution, just the plan) ----


def test_install_dry_run_plans_keychain_and_every_firefox_profile(
    ca_pem_file, firefox_dir, tmp_path
):
    keychain = str(tmp_path / "System.keychain")
    r = _run(
        "--ca-cert",
        ca_pem_file,
        "--keychain",
        keychain,
        "--firefox-dir",
        firefox_dir,
        "--dry-run",
        "install",
    )
    assert r.exit_code == 0, r.output
    assert "security add-trusted-cert" in r.output
    assert f"-k {keychain}" in r.output
    # one certutil -A per Firefox profile
    assert r.output.count("certutil -A") == 2
    assert "dry-run" in r.output


def test_install_dry_run_without_firefox_does_keychain_only(
    ca_pem_file, empty_firefox_dir, tmp_path
):
    r = _run(
        "--ca-cert",
        ca_pem_file,
        "--firefox-dir",
        empty_firefox_dir,
        "--dry-run",
        "install",
    )
    assert r.exit_code == 0, r.output
    assert "security add-trusted-cert" in r.output
    assert "certutil" not in r.output
    assert "no Firefox profiles found" in r.output


def test_remove_dry_run_plans_deletes(ca_pem_file, firefox_dir):
    r = _run(
        "--ca-cert",
        ca_pem_file,
        "--firefox-dir",
        firefox_dir,
        "--dry-run",
        "remove",
    )
    assert r.exit_code == 0, r.output
    assert "security delete-certificate" in r.output
    # removal keys off the cert's CN
    assert "lab internal CA test" in r.output
    assert r.output.count("certutil -D") == 2


# ---- install (real execution against stub binaries) ----


def test_install_executes_and_succeeds_with_stub_bins(
    ca_pem_file, firefox_dir, fake_bins, tmp_path
):
    keychain = str(tmp_path / "System.keychain")
    r = _run(
        "--ca-cert",
        ca_pem_file,
        "--keychain",
        keychain,
        "--firefox-dir",
        firefox_dir,
        "--yes",
        "install",
    )
    assert r.exit_code == 0, r.output


def test_install_reports_failure_when_keychain_command_fails(
    ca_pem_file, firefox_dir, fake_bins, tmp_path
):
    fake_bins("security", exit_code=1)  # security now fails
    r = _run(
        "--ca-cert",
        ca_pem_file,
        "--firefox-dir",
        firefox_dir,
        "--yes",
        "install",
    )
    assert r.exit_code == mt.pc.CHECK_FAIL_EXIT, r.output


# ---- resolution / errors ----


def test_missing_root_source_exits_nonzero(monkeypatch, tmp_path):
    # No --ca-cert, no pinned root, and tofu resolution will fail in the hermetic env.
    monkeypatch.setattr(mt, "PINNED_ROOT", tmp_path / "does-not-exist.crt")
    r = _run("--firefox-dir", str(tmp_path / "nf"), "install")
    assert r.exit_code != 0


def test_ca_cert_overrides_pinned(ca_pem_file, firefox_dir):
    r = _run(
        "--ca-cert", ca_pem_file, "--firefox-dir", firefox_dir, "--dry-run", "install"
    )
    assert r.exit_code == 0, r.output
