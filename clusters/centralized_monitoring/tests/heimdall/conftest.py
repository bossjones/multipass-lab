"""Fixtures for the hermetic heimdall_cli suite.

These tests never touch Multipass/Docker. They build a throwaway SQLite file with
Heimdall's real-ish `items` + `item_tag` schema and drive the CLI in `--db` (local)
mode, asserting on the rows it writes.
"""

import sqlite3

import pytest

# Mirrors the linuxserver/Heimdall schema for the columns the tool touches. `order`
# is a SQL reserved word, hence the quoting. Real Heimdall has a few more columns
# (settings, etc.) but the CLI probes columns at runtime, so this subset is faithful.
HEIMDALL_SCHEMA = """
CREATE TABLE items (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    title          VARCHAR  NOT NULL,
    url            TEXT,
    colour         VARCHAR,
    icon           VARCHAR,
    description    TEXT,
    appdescription TEXT,
    pinned         TINYINT  NOT NULL DEFAULT 0,
    "order"        INTEGER  NOT NULL DEFAULT 0,
    type           INTEGER  NOT NULL DEFAULT 0,
    class          VARCHAR,
    appid          VARCHAR,
    user_id        INTEGER  NOT NULL DEFAULT 0,
    created_at     DATETIME,
    updated_at     DATETIME,
    deleted_at     DATETIME
);
CREATE TABLE item_tag (
    item_id    INTEGER NOT NULL,
    tag_id     INTEGER NOT NULL,
    created_at DATETIME,
    updated_at DATETIME
);
"""


@pytest.fixture
def db(tmp_path):
    """Path to a fresh app.sqlite seeded with the Heimdall schema (no rows)."""
    path = tmp_path / "app.sqlite"
    conn = sqlite3.connect(path)
    conn.executescript(HEIMDALL_SCHEMA)
    conn.commit()
    conn.close()
    return path


def open_db(path):
    """Open the fixture DB with row access by column name."""
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    return conn
