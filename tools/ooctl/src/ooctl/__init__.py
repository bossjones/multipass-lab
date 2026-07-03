"""ooctl — async CLI to tail and search logs from an OpenObserve instance."""

from __future__ import annotations

__all__ = ["__version__"]

try:  # pragma: no cover - trivial import guard
    from importlib.metadata import PackageNotFoundError, version

    __version__ = version("ooctl")
except PackageNotFoundError:  # pragma: no cover - running from a source checkout
    __version__ = "0.0.0"
