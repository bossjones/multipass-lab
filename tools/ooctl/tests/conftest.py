"""Shared fixtures for ooctl hermetic tests."""

from __future__ import annotations

import textwrap

import pytest


@pytest.fixture
def config_file(tmp_path):
    """Write a tmp config with a 'default' profile; return its path.

    The endpoint is a placeholder — tests point the client at pytest-httpserver
    by setting ``OOCTL_ENDPOINT`` (which overrides the profile endpoint).
    """
    path = tmp_path / "config.yaml"
    path.write_text(
        textwrap.dedent(
            """
            profiles:
              default:
                endpoint: http://placeholder:5080
                organization: default
                username: admin@example.com
                password: "Complexpass#123"
            """
        )
    )
    return path
