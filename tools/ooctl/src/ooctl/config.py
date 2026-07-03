"""Profile configuration: load ``~/.ooctl/config.yaml`` and resolve a profile.

The config schema mirrors ``o2-cli``::

    profiles:
      default:
        endpoint: https://openobserve.company.com
        organization: default
        username: user@company.com
        password: your-password

Per-field env overrides (``OOCTL_ENDPOINT``/``OOCTL_ORG``/``OOCTL_USERNAME``/
``OOCTL_PASSWORD``) win over the selected profile so the lab justfile can inject a
DHCP-assigned endpoint without editing the file.
"""

from __future__ import annotations

import os
from pathlib import Path

import yaml
from pydantic import BaseModel, Field, ValidationError, field_validator

__all__ = [
    "Config",
    "ConfigError",
    "Profile",
    "default_config_path",
    "load_config",
    "resolve_profile",
]


class ConfigError(Exception):
    """Raised for missing/invalid config files or unknown profiles."""


class Profile(BaseModel):
    """A single OpenObserve connection profile."""

    endpoint: str
    organization: str = "default"
    username: str
    password: str
    timeout: float = 10.0
    verify: bool = True

    @field_validator("endpoint")
    @classmethod
    def _strip_trailing_slash(cls, v: str) -> str:
        return v.rstrip("/")


class Config(BaseModel):
    """Top-level config: a map of profile name -> Profile."""

    profiles: dict[str, Profile] = Field(default_factory=dict)


def default_config_path() -> Path:
    """Return the default config location: ``~/.ooctl/config.yaml``."""
    return Path.home() / ".ooctl" / "config.yaml"


def load_config(path: str | Path) -> Config:
    """Load and validate a config file.

    Raises ``ConfigError`` if the file is missing, unparseable, or has no
    ``profiles`` mapping.
    """
    path = Path(path)
    if not path.exists():
        raise ConfigError(f"config file not found: {path}")
    try:
        raw = yaml.safe_load(path.read_text()) or {}
    except yaml.YAMLError as exc:  # pragma: no cover - error path
        raise ConfigError(f"could not parse {path}: {exc}") from exc
    if not isinstance(raw, dict) or not raw.get("profiles"):
        raise ConfigError(f"no profiles defined in {path}")
    try:
        return Config.model_validate(raw)
    except ValidationError as exc:
        raise ConfigError(f"invalid config {path}:\n{exc}") from exc


# env var -> Profile field
_ENV_OVERRIDES = {
    "OOCTL_ENDPOINT": "endpoint",
    "OOCTL_ORG": "organization",
    "OOCTL_USERNAME": "username",
    "OOCTL_PASSWORD": "password",
}


def resolve_profile(
    config: Config,
    name: str,
    env: dict[str, str] | None = None,
) -> Profile:
    """Return the named profile with ``OOCTL_*`` env overrides applied.

    Raises ``ConfigError`` if ``name`` is not defined, listing the available
    profiles.
    """
    if name not in config.profiles:
        available = ", ".join(sorted(config.profiles)) or "(none)"
        raise ConfigError(f"unknown profile {name!r}; available profiles: {available}")
    if env is None:
        env = dict(os.environ)
    profile = config.profiles[name]
    overrides = {field: env[key] for key, field in _ENV_OVERRIDES.items() if env.get(key)}
    if not overrides:
        return profile
    # Re-validate through the model so field validators (e.g. endpoint
    # normalization) run on the overridden values too.
    return Profile.model_validate({**profile.model_dump(), **overrides})
