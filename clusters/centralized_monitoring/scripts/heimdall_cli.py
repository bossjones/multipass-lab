#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml"]
# ///
"""heimdall_cli — programmatic tile management for linuxserver/Heimdall.

Heimdall has no REST API and no artisan command for creating dashboard tiles, so
this tool edits its SQLite DB (`/config/www/app.sqlite`) directly. It works in two
modes:

  * --db PATH   operate on a local app.sqlite (used by tests and on-host edits).
  * remote      ssh to the server VM, `docker cp` the DB out, mutate it locally,
                copy it back, and chown it. No container restart needed — Heimdall
                re-reads items on the next page load.

Tiles are plain `items` rows (type=0). Visibility requires the counter-intuitive
`item_tag (item_id=0, tag_id=<id>)` pivot (tag 0 = the default dashboard). Every
tile this tool creates is also associated with a "managed-by-cli" tag so that
`sync --prune` only removes tiles it owns, never ones added by hand in the UI.

See specs/heimdall-config.md for the full design.
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

import yaml

# --- constants ---------------------------------------------------------------

DEFAULT_VM = "centralized-monitoring-server"
DEFAULT_CONTAINER = "heimdall"
DEFAULT_USER_ID = 1
REMOTE_DB_PATH = "/config/www/app.sqlite"
REMOTE_OWNER = "abc:abc"  # linuxserver images run as the `abc`/PUID user
MANAGED_TAG = "managed-by-cli"
RESERVED_COLUMNS = {"order"}

SSH_OPTS = [
    "-o",
    "StrictHostKeyChecking=no",
    "-o",
    "UserKnownHostsFile=/dev/null",
    "-o",
    "LogLevel=ERROR",
    "-o",
    "ConnectTimeout=8",
]

# The default, flag-aware tile catalog (the human-facing web UIs from
# docs/endpoints.md). enabled_when=None means a spine service that is always on.
CATALOG = [
    {
        "title": "Grafana",
        "port": 3000,
        "enabled_when": None,
        "icon": "grafana",
        "colour": "#161b1f",
    },
    {
        "title": "Prometheus",
        "port": 9090,
        "enabled_when": None,
        "icon": "prometheus",
        "colour": "#e6522c",
    },
    {
        "title": "Alertmanager",
        "port": 9093,
        "enabled_when": None,
        "icon": "prometheus",
        "colour": "#e6522c",
    },
    {
        "title": "OpenObserve",
        "port": 5080,
        "enabled_when": "enable_openobserve",
        "icon": "openobserve",
        "colour": "#3b1e54",
    },
    {
        "title": "Uptime Kuma",
        "port": 3001,
        "enabled_when": "enable_uptime_kuma",
        "icon": "uptime-kuma",
        "colour": "#5cdd8b",
    },
    {
        "title": "Traefik",
        "port": 8082,
        "enabled_when": "enable_traefik",
        "icon": "traefik",
        "colour": "#24a1c1",
    },
]


# --- pure helpers (config + catalog) -----------------------------------------


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def parse_tofu_output(tofu_json: dict) -> tuple[str, set[str]]:
    """Extract (server_ipv4, enabled_flags) from a parsed `tofu output -json`."""
    ip = tofu_json["server_ipv4"]["value"]
    flags = set(tofu_json.get("enabled_exporters", {}).get("value", []))
    return ip, flags


def build_catalog_tiles(server_ip: str, enabled_flags: set[str]) -> list[dict]:
    """Render the default tile set for a server IP, gated by enable_* flags."""
    tiles = []
    for entry in CATALOG:
        gate = entry["enabled_when"]
        if gate is not None and gate not in enabled_flags:
            continue
        tiles.append(
            {
                "title": entry["title"],
                "url": f"http://{server_ip}:{entry['port']}",
                "icon": entry["icon"],
                "colour": entry["colour"],
            }
        )
    return tiles


def _substitute(value, variables: dict) -> object:
    if isinstance(value, str):
        for name, replacement in variables.items():
            value = value.replace("{" + name + "}", str(replacement))
    return value


def load_config(path, variables: dict | None = None) -> list[dict]:
    """Load tiles from a YAML config, substituting `{name}` placeholders."""
    variables = variables or {}
    text = path.read_text() if hasattr(path, "read_text") else open(path).read()
    data = yaml.safe_load(text) or {}
    tiles = []
    for raw in data.get("tiles", []):
        tiles.append({k: _substitute(v, variables) for k, v in raw.items()})
    return tiles


def render_config_yaml(tiles: list[dict]) -> str:
    return yaml.safe_dump({"tiles": tiles}, sort_keys=False)


# --- SQLite layer ------------------------------------------------------------


def connect(path) -> sqlite3.Connection:
    conn = sqlite3.connect(str(path))
    conn.execute("PRAGMA busy_timeout = 5000")
    conn.row_factory = sqlite3.Row
    return conn


def _columns(conn, table) -> set[str]:
    return {r["name"] for r in conn.execute(f"PRAGMA table_info({table})")}


def _q(col: str) -> str:
    return f'"{col}"' if col in RESERVED_COLUMNS else col


def _insert(conn, table, values: dict) -> int:
    cols = _columns(conn, table)
    used = {k: v for k, v in values.items() if k in cols}
    names = ", ".join(_q(c) for c in used)
    holes = ", ".join("?" for _ in used)
    conn.execute(f"INSERT INTO {table} ({names}) VALUES ({holes})", list(used.values()))
    return conn.execute("SELECT last_insert_rowid()").fetchone()[0]


def _update(conn, table, values: dict, where: str, params: tuple) -> None:
    cols = _columns(conn, table)
    used = {k: v for k, v in values.items() if k in cols}
    assigns = ", ".join(f"{_q(c)} = ?" for c in used)
    conn.execute(
        f"UPDATE {table} SET {assigns} WHERE {where}",
        list(used.values()) + list(params),
    )


def ensure_tag(conn, title, user_id) -> int:
    """Return the id of a tag/category item (type=1), creating it if absent."""
    row = conn.execute(
        "SELECT id FROM items WHERE title = ? AND type = 1 AND deleted_at IS NULL",
        (title,),
    ).fetchone()
    if row:
        return row["id"]
    now = _now()
    return _insert(
        conn,
        "items",
        {
            "title": title,
            "url": title.lower().replace(" ", "-"),
            "type": 1,
            "user_id": user_id,
            "created_at": now,
            "updated_at": now,
        },
    )


def ensure_pivot(conn, parent_id, child_id) -> None:
    """Ensure item_tag(item_id=parent, tag_id=child) exists (idempotent)."""
    if conn.execute(
        "SELECT 1 FROM item_tag WHERE item_id = ? AND tag_id = ?",
        (parent_id, child_id),
    ).fetchone():
        return
    now = _now()
    _insert(
        conn,
        "item_tag",
        {
            "item_id": parent_id,
            "tag_id": child_id,
            "created_at": now,
            "updated_at": now,
        },
    )


def upsert_tile(conn, tile: dict, user_id: int) -> int:
    """Idempotently create/update a tile and its dashboard + managed pivots."""
    managed_id = ensure_tag(conn, MANAGED_TAG, user_id)
    title = tile["title"]
    now = _now()
    mutable = {
        "url": tile.get("url", ""),
        "colour": tile.get("colour"),
        "icon": tile.get("icon"),
        "pinned": 1 if tile.get("pinned") else 0,
        "order": tile.get("order", 0),
        "updated_at": now,
    }

    existing = conn.execute(
        "SELECT id FROM items WHERE title = ? AND user_id = ? AND type = 0 "
        "AND deleted_at IS NULL",
        (title, user_id),
    ).fetchone()

    if existing:
        item_id = existing["id"]
        _update(conn, "items", mutable, "id = ?", (item_id,))
    else:
        item_id = _insert(
            conn,
            "items",
            {
                "title": title,
                "type": 0,
                "user_id": user_id,
                "description": "",
                "created_at": now,
                **mutable,
            },
        )

    parent = ensure_tag(conn, tile["tag"], user_id) if tile.get("tag") else 0
    ensure_pivot(conn, parent, item_id)  # dashboard / category placement
    ensure_pivot(conn, managed_id, item_id)  # managed-by-cli marker
    return item_id


def soft_delete_tile(conn, title, user_id) -> None:
    conn.execute(
        "UPDATE items SET deleted_at = ? WHERE title = ? AND user_id = ? "
        "AND type = 0 AND deleted_at IS NULL",
        (_now(), title, user_id),
    )


def hard_delete_tile(conn, title, user_id) -> None:
    rows = conn.execute(
        "SELECT id FROM items WHERE title = ? AND user_id = ? AND type = 0",
        (title, user_id),
    ).fetchall()
    for row in rows:
        conn.execute("DELETE FROM item_tag WHERE tag_id = ?", (row["id"],))
        conn.execute("DELETE FROM items WHERE id = ?", (row["id"],))


def list_tiles(conn, user_id) -> list[dict]:
    rows = conn.execute(
        "SELECT id, title, url, icon, colour FROM items WHERE type = 0 "
        'AND deleted_at IS NULL AND user_id = ? ORDER BY "order", title',
        (user_id,),
    ).fetchall()
    return [dict(r) for r in rows]


def _managed_tile_titles(conn, user_id) -> set[str]:
    managed_id = ensure_tag(conn, MANAGED_TAG, user_id)
    rows = conn.execute(
        "SELECT i.title FROM items i JOIN item_tag t ON t.tag_id = i.id "
        "WHERE t.item_id = ? AND i.type = 0 AND i.deleted_at IS NULL "
        "AND i.user_id = ?",
        (managed_id, user_id),
    ).fetchall()
    return {r["title"] for r in rows}


def sync_tiles(conn, tiles: list[dict], user_id: int, prune: bool) -> None:
    desired = set()
    for tile in tiles:
        upsert_tile(conn, tile, user_id)
        desired.add(tile["title"])
    if prune:
        for title in _managed_tile_titles(conn, user_id) - desired:
            soft_delete_tile(conn, title, user_id)


# --- remote transport (ssh + docker cp) --------------------------------------


def _run(cmd, capture=False, check=True):
    return subprocess.run(cmd, text=True, capture_output=capture, check=check)


def resolve_server_ip(chdir: str) -> str:
    result = _run(
        ["tofu", f"-chdir={chdir}", "output", "-raw", "server_ipv4"],
        capture=True,
    )
    return result.stdout.strip()


def _ssh(ip: str, *remote_cmd: str, capture=False, check=True):
    return _run(
        ["ssh", *SSH_OPTS, f"ubuntu@{ip}", *remote_cmd], capture=capture, check=check
    )


def pause_container(ip, container) -> None:
    _ssh(ip, "docker", "pause", container, check=False)


def unpause_container(ip, container) -> None:
    _ssh(ip, "docker", "unpause", container, check=False)


def pull_remote_db(ip, container) -> str:
    """Copy app.sqlite out of the container to a local temp file; return its path."""
    remote_tmp = "/tmp/heimdall-app.sqlite"
    _ssh(ip, "docker", "cp", f"{container}:{REMOTE_DB_PATH}", remote_tmp)
    local = tempfile.NamedTemporaryFile(suffix=".sqlite", delete=False).name
    _run(["scp", *SSH_OPTS, f"ubuntu@{ip}:{remote_tmp}", local])
    return local


def push_remote_db(ip, container, local_path) -> None:
    """Copy the mutated DB back into the container (paused-safe: file copy only)."""
    remote_tmp = "/tmp/heimdall-app.sqlite"
    _run(["scp", *SSH_OPTS, local_path, f"ubuntu@{ip}:{remote_tmp}"])
    _ssh(ip, "docker", "cp", remote_tmp, f"{container}:{REMOTE_DB_PATH}")


def with_remote_db(ip, container, mutate) -> None:
    pause_container(ip, container)
    local_path = None
    try:
        local_path = pull_remote_db(ip, container)
        conn = connect(local_path)
        try:
            mutate(conn)
            conn.commit()
        finally:
            conn.close()
        push_remote_db(ip, container, local_path)
    finally:
        unpause_container(ip, container)
        if local_path and os.path.exists(local_path):
            os.unlink(local_path)
    # `docker exec` refuses a paused container, so restore ownership (docker cp
    # lands the file as root) only after unpause. Reached only on the success
    # path — an exception above propagates through `finally` and skips this.
    _ssh(ip, "docker", "exec", container, "chown", REMOTE_OWNER, REMOTE_DB_PATH)


# --- local transport (on-host, docker compose) -------------------------------
# Used by the cloud-init `seed` path: the tool runs ON the server VM, so there is
# no ssh — it reaches the container by compose *service* name via `docker compose`
# (the compose file also pins container_name=heimdall so the remote `docker cp`
# transport can address it by that name). Mirrors the remote transport otherwise.


def _compose(compose_file, *args, capture=False, check=True):
    return _run(
        ["docker", "compose", "-f", compose_file, *args], capture=capture, check=check
    )


def pause_local_container(compose_file, container) -> None:
    _compose(compose_file, "pause", container, check=False)


def unpause_local_container(compose_file, container) -> None:
    _compose(compose_file, "unpause", container, check=False)


def pull_local_db(compose_file, container) -> str:
    """Copy app.sqlite out of the local container to a temp file; return its path."""
    local = tempfile.NamedTemporaryFile(suffix=".sqlite", delete=False).name
    _compose(compose_file, "cp", f"{container}:{REMOTE_DB_PATH}", local)
    return local


def push_local_db(compose_file, container, local_path) -> None:
    """Copy the mutated DB back into the local container (paused-safe: file copy only)."""
    _compose(compose_file, "cp", local_path, f"{container}:{REMOTE_DB_PATH}")


def with_local_db(compose_file, container, mutate) -> None:
    pause_local_container(compose_file, container)
    local_path = None
    try:
        local_path = pull_local_db(compose_file, container)
        conn = connect(local_path)
        try:
            mutate(conn)
            conn.commit()
        finally:
            conn.close()
        push_local_db(compose_file, container, local_path)
    finally:
        unpause_local_container(compose_file, container)
        if local_path and os.path.exists(local_path):
            os.unlink(local_path)
    # `docker exec` refuses a paused container, so restore ownership (docker cp
    # lands the file as root) only after unpause. Reached only on the success
    # path — an exception above propagates through `finally` and skips this.
    _compose(
        compose_file, "exec", "-T", container, "chown", REMOTE_OWNER, REMOTE_DB_PATH
    )


# --- command dispatch --------------------------------------------------------


def _tile_from_args(args) -> dict:
    return {
        "title": args.title,
        "url": args.url,
        "icon": args.icon,
        "colour": args.colour,
        "tag": args.tag,
        "pinned": getattr(args, "pinned", False),
    }


def _apply(args, conn) -> None:
    """Run a mutating subcommand against an open connection."""
    if args.cmd == "add":
        upsert_tile(conn, _tile_from_args(args), args.user_id)
    elif args.cmd == "remove":
        if args.hard:
            hard_delete_tile(conn, args.title, args.user_id)
        else:
            soft_delete_tile(conn, args.title, args.user_id)
    elif args.cmd == "sync":
        variables = (
            {"server_ip": args.server_ip} if getattr(args, "server_ip", None) else {}
        )
        tiles = load_config(args.config, variables)
        sync_tiles(conn, tiles, args.user_id, args.prune)


def _run_mutation(args) -> None:
    if args.db:
        conn = connect(args.db)
        try:
            _apply(args, conn)
            conn.commit()
        finally:
            conn.close()
    else:
        ip = resolve_server_ip(args.chdir)
        if args.cmd == "sync":
            args.server_ip = ip
        with_remote_db(ip, args.container, lambda conn: _apply(args, conn))


def _cmd_list(args) -> None:
    if args.db:
        conn = connect(args.db)
        cleanup = None
    else:
        ip = resolve_server_ip(args.chdir)
        local = pull_remote_db(ip, args.container)
        conn = connect(local)
        cleanup = local
    try:
        tiles = list_tiles(conn, args.user_id)
    finally:
        conn.close()
        if cleanup and os.path.exists(cleanup):
            os.unlink(cleanup)

    if args.json:
        print(json.dumps(tiles, indent=2))
    else:
        for tile in tiles:
            print(f"{tile['title']}\t{tile['url']}")


def _cmd_generate(args) -> None:
    raw = _run(["tofu", f"-chdir={args.chdir}", "output", "-json"], capture=True).stdout
    ip, flags = parse_tofu_output(json.loads(raw))
    tiles = build_catalog_tiles(ip, flags)
    out = render_config_yaml(tiles)
    if args.output:
        with open(args.output, "w") as fh:
            fh.write(out)
        print(f"wrote {len(tiles)} tiles to {args.output}")
    else:
        sys.stdout.write(out)


def _cmd_seed(args) -> None:
    """Populate Heimdall from the built-in catalog (the cloud-init / on-host path).

    Unlike `sync`, this needs no tofu and no config file: the flag set and server
    IP are passed in (discovered at runtime on the VM), and tiles come from
    `build_catalog_tiles`. Uses the local-docker transport unless `--db` is given.
    """
    flags = {f.strip() for f in (args.enabled or "").split(",") if f.strip()}
    tiles = build_catalog_tiles(args.server_ip, flags)

    def mutate(conn):
        sync_tiles(conn, tiles, args.user_id, args.prune)

    if args.db:
        conn = connect(args.db)
        try:
            mutate(conn)
            conn.commit()
        finally:
            conn.close()
    else:
        with_local_db(args.compose_file, args.container, mutate)


# --- argument parsing --------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--db", help="operate on a local app.sqlite (skip ssh/docker)")
    common.add_argument("--vm", "--instance", dest="vm", default=DEFAULT_VM)
    common.add_argument("--container", default=DEFAULT_CONTAINER)
    common.add_argument("--user-id", type=int, default=DEFAULT_USER_ID)
    common.add_argument("--chdir", default=".", help="cluster dir for `tofu output`")

    parser = argparse.ArgumentParser(prog="heimdall-cli", description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_add = sub.add_parser("add", parents=[common], help="upsert a single tile")
    p_add.add_argument("--title", required=True)
    p_add.add_argument("--url", required=True)
    p_add.add_argument("--icon")
    p_add.add_argument("--colour", "--color", dest="colour")
    p_add.add_argument("--tag")
    p_add.add_argument("--pinned", action="store_true")

    p_rm = sub.add_parser("remove", parents=[common], help="delete a tile")
    p_rm.add_argument("--title", required=True)
    p_rm.add_argument("--tag")
    p_rm.add_argument("--hard", action="store_true", help="hard DELETE (default: soft)")

    p_list = sub.add_parser("list", parents=[common], help="list active tiles")
    p_list.add_argument("--json", action="store_true")

    p_sync = sub.add_parser("sync", parents=[common], help="reconcile DB to a config")
    p_sync.add_argument("--config", required=True)
    p_sync.add_argument("--prune", action="store_true")

    p_gen = sub.add_parser(
        "generate", parents=[common], help="emit tiles.yaml from tofu"
    )
    p_gen.add_argument("--from-tofu", action="store_true", default=True)
    p_gen.add_argument("-o", "--output")

    p_seed = sub.add_parser(
        "seed", parents=[common], help="seed the catalog on-host (cloud-init path)"
    )
    p_seed.add_argument("--server-ip", required=True, help="server IP for tile URLs")
    p_seed.add_argument("--enabled", default="", help="comma-separated enable_* flags")
    p_seed.add_argument("--compose-file", default="/opt/stack/compose.yaml")
    p_seed.add_argument("--prune", action="store_true")

    return parser


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    if args.cmd in ("add", "remove", "sync"):
        _run_mutation(args)
    elif args.cmd == "list":
        _cmd_list(args)
    elif args.cmd == "generate":
        _cmd_generate(args)
    elif args.cmd == "seed":
        _cmd_seed(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
