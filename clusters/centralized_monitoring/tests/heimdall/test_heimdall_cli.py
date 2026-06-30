"""Hermetic behavior tests for heimdall_cli (TDD).

Every test drives the CLI in `--db` local mode against a throwaway Heimdall-schema
SQLite file, or calls a pure helper directly. No Docker, no SSH, no Multipass.
"""

import json

import heimdall_cli as hc
import pytest
from conftest import open_db


def _tiles(db, user_id=1):
    """Active (non-deleted) tile rows for a db path, keyed by title."""
    conn = open_db(db)
    rows = conn.execute(
        "SELECT * FROM items WHERE type = 0 AND deleted_at IS NULL AND user_id = ?",
        (user_id,),
    ).fetchall()
    conn.close()
    return {r["title"]: r for r in rows}


def _dashboard_children(db, parent_id=0):
    """tag_id values pivoted under a given parent tag (0 = default dashboard)."""
    conn = open_db(db)
    rows = conn.execute(
        "SELECT tag_id FROM item_tag WHERE item_id = ?", (parent_id,)
    ).fetchall()
    conn.close()
    return {r["tag_id"] for r in rows}


# --------------------------------------------------------------------------- add


def test_add_creates_item_and_dashboard_pivot(db):
    hc.main(["add", "--db", str(db), "--title", "Grafana", "--url", "http://x:3000"])

    tiles = _tiles(db)
    assert "Grafana" in tiles
    assert tiles["Grafana"]["url"] == "http://x:3000"
    assert tiles["Grafana"]["type"] == 0
    # The mandatory item_tag(0, id) row must exist or the tile is invisible.
    assert tiles["Grafana"]["id"] in _dashboard_children(db, 0)


def test_add_sets_optional_fields(db):
    hc.main(
        [
            "add", "--db", str(db),
            "--title", "Grafana", "--url", "http://x:3000",
            "--icon", "grafana", "--colour", "#161b1f",
        ]
    )
    row = _tiles(db)["Grafana"]
    assert row["icon"] == "grafana"
    assert row["colour"] == "#161b1f"


def test_add_is_idempotent(db):
    for _ in range(3):
        hc.main(["add", "--db", str(db), "--title", "Grafana", "--url", "http://x:3000"])

    conn = open_db(db)
    count = conn.execute(
        "SELECT COUNT(*) c FROM items WHERE title = 'Grafana' AND deleted_at IS NULL"
    ).fetchone()["c"]
    # Exactly one tile, one dashboard pivot row — no duplicates.
    pivots = conn.execute(
        "SELECT COUNT(*) c FROM item_tag WHERE item_id = 0 AND tag_id = "
        "(SELECT id FROM items WHERE title = 'Grafana')"
    ).fetchone()["c"]
    conn.close()
    assert count == 1
    assert pivots == 1


def test_add_updates_existing_tile(db):
    hc.main(["add", "--db", str(db), "--title", "Grafana", "--url", "http://old:3000"])
    hc.main(["add", "--db", str(db), "--title", "Grafana", "--url", "http://new:3000"])
    assert _tiles(db)["Grafana"]["url"] == "http://new:3000"


def test_add_with_custom_tag_pivots_under_that_tag(db):
    hc.main(
        [
            "add", "--db", str(db),
            "--title", "Grafana", "--url", "http://x:3000",
            "--tag", "Monitoring",
        ]
    )
    conn = open_db(db)
    tag = conn.execute(
        "SELECT id FROM items WHERE title = 'Monitoring' AND type = 1"
    ).fetchone()
    tile = conn.execute(
        "SELECT id FROM items WHERE title = 'Grafana' AND type = 0"
    ).fetchone()
    conn.close()
    assert tag is not None  # the tag/category row was created
    assert tile["id"] in _dashboard_children(db, tag["id"])  # pivoted under it


# ------------------------------------------------------------------------ remove


def test_remove_soft_deletes_by_default(db):
    hc.main(["add", "--db", str(db), "--title", "Grafana", "--url", "http://x:3000"])
    hc.main(["remove", "--db", str(db), "--title", "Grafana"])

    assert "Grafana" not in _tiles(db)  # hidden from active set
    conn = open_db(db)
    row = conn.execute("SELECT deleted_at FROM items WHERE title = 'Grafana'").fetchone()
    conn.close()
    assert row is not None and row["deleted_at"] is not None  # row still present


def test_remove_hard_deletes_with_flag(db):
    hc.main(["add", "--db", str(db), "--title", "Grafana", "--url", "http://x:3000"])
    hc.main(["remove", "--db", str(db), "--title", "Grafana", "--hard"])

    conn = open_db(db)
    row = conn.execute("SELECT id FROM items WHERE title = 'Grafana'").fetchone()
    conn.close()
    assert row is None


# -------------------------------------------------------------------------- list


def test_list_excludes_soft_deleted(db, capsys):
    hc.main(["add", "--db", str(db), "--title", "Grafana", "--url", "http://x:3000"])
    hc.main(["add", "--db", str(db), "--title", "Prometheus", "--url", "http://x:9090"])
    hc.main(["remove", "--db", str(db), "--title", "Prometheus"])
    capsys.readouterr()  # drop prior output

    hc.main(["list", "--db", str(db)])
    out = capsys.readouterr().out
    assert "Grafana" in out
    assert "Prometheus" not in out


def test_list_json_is_parseable(db, capsys):
    hc.main(["add", "--db", str(db), "--title", "Grafana", "--url", "http://x:3000"])
    capsys.readouterr()

    hc.main(["list", "--db", str(db), "--json"])
    data = json.loads(capsys.readouterr().out)
    assert [t["title"] for t in data] == ["Grafana"]


# -------------------------------------------------------------------------- sync


def _write_config(path, tiles):
    import yaml

    path.write_text(yaml.safe_dump({"tiles": tiles}))
    return path


def test_sync_adds_config_tiles(db, tmp_path):
    cfg = _write_config(
        tmp_path / "tiles.yaml",
        [
            {"title": "Grafana", "url": "http://x:3000"},
            {"title": "Prometheus", "url": "http://x:9090"},
        ],
    )
    hc.main(["sync", "--db", str(db), "--config", str(cfg)])
    assert set(_tiles(db)) == {"Grafana", "Prometheus"}


def test_sync_is_idempotent(db, tmp_path):
    cfg = _write_config(tmp_path / "tiles.yaml", [{"title": "Grafana", "url": "http://x:3000"}])
    hc.main(["sync", "--db", str(db), "--config", str(cfg)])
    hc.main(["sync", "--db", str(db), "--config", str(cfg)])

    conn = open_db(db)
    count = conn.execute(
        "SELECT COUNT(*) c FROM items WHERE title = 'Grafana' AND deleted_at IS NULL"
    ).fetchone()["c"]
    conn.close()
    assert count == 1


def test_sync_prune_removes_managed_tiles_absent_from_config(db, tmp_path):
    # Two managed tiles, then a config that only keeps one.
    full = _write_config(
        tmp_path / "full.yaml",
        [{"title": "Grafana", "url": "http://x:3000"}, {"title": "Loki", "url": "http://x:3100"}],
    )
    hc.main(["sync", "--db", str(db), "--config", str(full)])

    trimmed = _write_config(tmp_path / "trim.yaml", [{"title": "Grafana", "url": "http://x:3000"}])
    hc.main(["sync", "--db", str(db), "--config", str(trimmed), "--prune"])

    assert set(_tiles(db)) == {"Grafana"}  # Loki pruned


def test_sync_prune_keeps_hand_added_tiles(db, tmp_path):
    # A tile added directly in the UI (no managed marker) must survive --prune.
    conn = open_db(db)
    conn.execute(
        "INSERT INTO items (title, url, type, user_id) VALUES ('HandMade', 'http://h', 0, 1)"
    )
    hand_id = conn.execute("SELECT id FROM items WHERE title='HandMade'").fetchone()[0]
    conn.execute("INSERT INTO item_tag (item_id, tag_id) VALUES (0, ?)", (hand_id,))
    conn.commit()
    conn.close()

    cfg = _write_config(tmp_path / "tiles.yaml", [{"title": "Grafana", "url": "http://x:3000"}])
    hc.main(["sync", "--db", str(db), "--config", str(cfg), "--prune"])

    assert "HandMade" in _tiles(db)  # untouched by prune


# --------------------------------------------------------------- generate (pure)


def _tofu_json(server_ip, enabled):
    return {
        "server_ipv4": {"value": server_ip},
        "enabled_exporters": {"value": enabled},
    }


def test_parse_tofu_output_extracts_ip_and_flags():
    ip, flags = hc.parse_tofu_output(_tofu_json("10.0.0.5", ["enable_traefik"]))
    assert ip == "10.0.0.5"
    assert flags == {"enable_traefik"}


def test_generate_includes_spine_and_substitutes_ip():
    tiles = hc.build_catalog_tiles("10.0.0.5", set())
    by_title = {t["title"]: t for t in tiles}
    # Spine services are always present regardless of flags.
    assert {"Grafana", "Prometheus", "Alertmanager"} <= set(by_title)
    assert by_title["Grafana"]["url"] == "http://10.0.0.5:3000"


def test_generate_honors_enable_flags():
    without = {t["title"] for t in hc.build_catalog_tiles("10.0.0.5", set())}
    assert "Traefik" not in without  # enable_traefik off -> no tile

    withflag = {t["title"] for t in hc.build_catalog_tiles("10.0.0.5", {"enable_traefik"})}
    assert "Traefik" in withflag


# ----------------------------------------------------------------- config loader


def test_load_config_substitutes_placeholders(tmp_path):
    cfg = _write_config(
        tmp_path / "tiles.yaml",
        [{"title": "Grafana", "url": "http://{server_ip}:3000"}],
    )
    tiles = hc.load_config(cfg, {"server_ip": "10.0.0.9"})
    assert tiles[0]["url"] == "http://10.0.0.9:3000"


# ---------------------------------------------------------- remote transport seam


def test_remote_mode_issues_docker_cp(db, tmp_path, mocker):
    """Without --db, the CLI must pull the DB, mutate it, and push it back.

    `pull` hands back a real temp copy (which the tool deletes after pushing), so
    we capture the mutated rows inside the `push` stub before cleanup runs.
    """
    import shutil

    def fake_pull(ip, container):
        return str(shutil.copy(db, tmp_path / "pulled.sqlite"))

    pushed = {}

    def fake_push(ip, container, local_path):
        conn = open_db(local_path)
        pushed["titles"] = {
            r["title"]
            for r in conn.execute(
                "SELECT title FROM items WHERE type = 0 AND deleted_at IS NULL"
            )
        }
        conn.close()

    mocker.patch.object(hc, "resolve_server_ip", return_value="10.0.0.5")
    mocker.patch.object(hc, "pull_remote_db", side_effect=fake_pull)
    mocker.patch.object(hc, "push_remote_db", side_effect=fake_push)
    mocker.patch.object(hc, "_run")  # neutralize pause/unpause ssh calls

    hc.main(["add", "--title", "Grafana", "--url", "http://x:3000",
             "--chdir", "/some/cluster"])

    # The tool pushed a DB back, and the mutation was in it.
    assert pushed.get("titles") == {"Grafana"}


# ------------------------------------------------ seed (catalog, cloud-init path)


def test_seed_db_mode_seeds_spine(db):
    hc.main(["seed", "--db", str(db), "--server-ip", "10.0.0.5", "--enabled", ""])
    tiles = _tiles(db)
    assert {"Grafana", "Prometheus", "Alertmanager"} <= set(tiles)
    assert tiles["Grafana"]["url"] == "http://10.0.0.5:3000"
    assert "Traefik" not in tiles  # flag off -> no tile


def test_seed_honors_enabled_flags(db):
    hc.main(
        ["seed", "--db", str(db), "--server-ip", "10.0.0.5",
         "--enabled", "enable_traefik,enable_openobserve"]
    )
    tiles = set(_tiles(db))
    assert {"Traefik", "OpenObserve"} <= tiles


def test_seed_is_idempotent(db):
    for _ in range(2):
        hc.main(["seed", "--db", str(db), "--server-ip", "10.0.0.5", "--enabled", "enable_traefik"])
    conn = open_db(db)
    count = conn.execute(
        "SELECT COUNT(*) c FROM items WHERE title = 'Traefik' AND deleted_at IS NULL"
    ).fetchone()["c"]
    conn.close()
    assert count == 1


def test_seed_prune_drops_now_disabled_tiles(db):
    hc.main(["seed", "--db", str(db), "--server-ip", "10.0.0.5", "--enabled", "enable_traefik", "--prune"])
    assert "Traefik" in _tiles(db)
    # Re-seed with traefik off; --prune should remove the managed-but-absent tile.
    hc.main(["seed", "--db", str(db), "--server-ip", "10.0.0.5", "--enabled", "", "--prune"])
    tiles = _tiles(db)
    assert "Traefik" not in tiles
    assert "Grafana" in tiles  # spine survives


def test_seed_local_docker_mode(db, tmp_path, mocker):
    """Without --db, seed uses the local-docker transport (no ssh)."""
    import shutil

    def fake_pull(compose_file, container):
        return str(shutil.copy(db, tmp_path / "pulled.sqlite"))

    pushed = {}

    def fake_push(compose_file, container, local_path):
        conn = open_db(local_path)
        pushed["titles"] = {
            r["title"]
            for r in conn.execute(
                "SELECT title FROM items WHERE type = 0 AND deleted_at IS NULL"
            )
        }
        conn.close()

    mocker.patch.object(hc, "pull_local_db", side_effect=fake_pull)
    mocker.patch.object(hc, "push_local_db", side_effect=fake_push)
    mocker.patch.object(hc, "_run")  # neutralize pause/unpause

    hc.main(["seed", "--compose-file", "/opt/stack/compose.yaml",
             "--server-ip", "10.0.0.5", "--enabled", "enable_traefik"])

    assert {"Grafana", "Traefik"} <= pushed.get("titles", set())


def test_local_transport_command_shapes(mocker):
    """The local-docker transport must talk to the heimdall service via compose."""
    recorded = []

    class _R:
        returncode = 0
        stdout = ""
        stderr = ""

    def rec(cmd, **kwargs):
        recorded.append(cmd)
        return _R()

    mocker.patch.object(hc, "_run", side_effect=rec)
    hc.pause_local_container("/opt/stack/compose.yaml", "heimdall")
    hc.push_local_db("/opt/stack/compose.yaml", "heimdall", "/tmp/x.sqlite")

    flat = [" ".join(c) for c in recorded]
    assert any("docker compose -f /opt/stack/compose.yaml pause heimdall" in f for f in flat)
    assert any(
        "docker compose -f /opt/stack/compose.yaml cp /tmp/x.sqlite "
        "heimdall:/config/www/app.sqlite" in f
        for f in flat
    )
    assert any("exec -T heimdall chown abc:abc /config/www/app.sqlite" in f for f in flat)


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(pytest.main([__file__, "-v"]))
