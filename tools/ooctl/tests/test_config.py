"""Tests for ooctl.config — profile loading, resolution, and env overrides."""

from __future__ import annotations

import textwrap

import pytest

from ooctl.config import (
    Config,
    ConfigError,
    Profile,
    default_config_path,
    load_config,
    resolve_profile,
)

SAMPLE = textwrap.dedent(
    """
    profiles:
      default:
        endpoint: http://127.0.0.1:5080
        organization: default
        username: admin@example.com
        password: "Complexpass#123"
      dev:
        endpoint: https://dev.openobserve.com/
        organization: dev-org
        username: dev-user@company.com
        password: dev-password
        timeout: 30
        verify: false
    """
)


def _write(tmp_path, text=SAMPLE):
    p = tmp_path / "config.yaml"
    p.write_text(text)
    return p


def test_default_config_path_is_under_home():
    path = default_config_path()
    assert path.name == "config.yaml"
    assert path.parent.name == ".ooctl"


def test_load_config_parses_profiles(tmp_path):
    cfg = load_config(_write(tmp_path))
    assert isinstance(cfg, Config)
    assert set(cfg.profiles) == {"default", "dev"}
    default = cfg.profiles["default"]
    assert isinstance(default, Profile)
    assert default.endpoint == "http://127.0.0.1:5080"
    assert default.organization == "default"
    assert default.username == "admin@example.com"
    assert default.password == "Complexpass#123"
    assert default.timeout == 10.0  # default
    assert default.verify is True  # default


def test_profile_optional_fields_parsed(tmp_path):
    cfg = load_config(_write(tmp_path))
    dev = cfg.profiles["dev"]
    assert dev.timeout == 30.0
    assert dev.verify is False


def test_endpoint_trailing_slash_normalized(tmp_path):
    cfg = load_config(_write(tmp_path))
    assert cfg.profiles["dev"].endpoint == "https://dev.openobserve.com"


def test_load_config_missing_file_raises(tmp_path):
    with pytest.raises(ConfigError) as exc:
        load_config(tmp_path / "nope.yaml")
    assert "not found" in str(exc.value).lower()


def test_load_config_empty_or_no_profiles_raises(tmp_path):
    p = tmp_path / "config.yaml"
    p.write_text("other: 1\n")
    with pytest.raises(ConfigError):
        load_config(p)


def test_resolve_profile_returns_named(tmp_path):
    cfg = load_config(_write(tmp_path))
    prof = resolve_profile(cfg, "dev", env={})
    assert prof.organization == "dev-org"


def test_resolve_profile_unknown_lists_available(tmp_path):
    cfg = load_config(_write(tmp_path))
    with pytest.raises(ConfigError) as exc:
        resolve_profile(cfg, "missing", env={})
    msg = str(exc.value)
    assert "missing" in msg
    assert "default" in msg and "dev" in msg  # available profiles listed


def test_env_overrides_win_over_profile(tmp_path):
    cfg = load_config(_write(tmp_path))
    env = {
        "OOCTL_ENDPOINT": "http://10.0.0.5:5080",
        "OOCTL_ORG": "override-org",
        "OOCTL_USERNAME": "override@x.com",
        "OOCTL_PASSWORD": "override-pass",
    }
    prof = resolve_profile(cfg, "default", env=env)
    assert prof.endpoint == "http://10.0.0.5:5080"
    assert prof.organization == "override-org"
    assert prof.username == "override@x.com"
    assert prof.password == "override-pass"


def test_env_override_endpoint_only_keeps_other_fields(tmp_path):
    cfg = load_config(_write(tmp_path))
    prof = resolve_profile(cfg, "default", env={"OOCTL_ENDPOINT": "http://10.0.0.9:5080"})
    assert prof.endpoint == "http://10.0.0.9:5080"
    assert prof.username == "admin@example.com"  # unchanged
    assert prof.password == "Complexpass#123"


def test_env_override_endpoint_trailing_slash_normalized(tmp_path):
    cfg = load_config(_write(tmp_path))
    prof = resolve_profile(cfg, "default", env={"OOCTL_ENDPOINT": "http://10.0.0.9:5080/"})
    assert prof.endpoint == "http://10.0.0.9:5080"
