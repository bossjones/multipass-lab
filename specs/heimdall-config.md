# Spec: Heimdall Tile Configuration (`heimdall-cli`)

## Context

`clusters/centralized_monitoring` deploys **Heimdall** (`lscr.io/linuxserver/heimdall:latest`)
as a Reach-tier, default-ON service — the homepage/link dashboard meant to front the whole
observability stack (Grafana, Prometheus, Alertmanager, OpenObserve, Uptime Kuma, Traefik).

**Current state — three answers up front:**

1. **Does Heimdall have all the endpoints configured?** **No.** It ships *completely empty*.
   The container boots a fresh SQLite DB into the persistent `heimdall_config` volume with zero
   tiles. Every link must be added by hand in the web UI — and because VMs are recreated on
   every `just up` and the volume is destroyed on `just destroy`, that manual work is lost on each
   bring-up.
2. **Is there a native programmatic CLI/API?** **No.** Heimdall (a Laravel/PHP app) exposes
   **no stable REST API** and **no artisan command** to create a user tile. Its only artisan
   command in this space — `register:app` — registers a *supported-app definition*, not a
   dashboard tile.
3. **So how do we get programmatic add/delete?** The only practical surface is Heimdall's
   **SQLite database** at `/config/www/app.sqlite` inside the container. This spec designs a
   small **uv single-file Python CLI** (`heimdall-cli`) that edits that DB via a `docker cp`
   round-trip, idempotently, driven by **either freeform CLI args or a config file**.

This document is a build-ready design. **It does not implement the tool** — implementation is a
follow-up. It conforms to the repo conventions in `CLAUDE.md`: uv single-file scripts, Bash
routed through `rtk`, the two-layer (hermetic + testinfra) test split, and Justfile recipes
parametrized by **cluster folder name**.

## Objective

Ship `heimdall-cli` — a Python CLI that **idempotently** adds, removes, lists, and syncs
Heimdall dashboard tiles for the `centralized_monitoring` cluster, with two input modes:

- **Freeform:** `add` / `remove` / `list` single tiles from command-line flags.
- **Declarative:** `sync` the DB to a committed `tiles.yaml` config (the source of truth), and
  `generate` that config from `tofu output -json` so only **enabled** services get tiles.

Wired in via `just heimdall-*` recipes and covered by a hermetic pytest suite plus a live
testinfra check.

## Architecture

```
  operator laptop                          centralized-monitoring-server VM
  ┌────────────────────┐                   ┌──────────────────────────────────┐
  │ heimdall-cli (uv)  │  multipass exec   │ docker: heimdall container        │
  │                    │ ────────────────► │   /config/www/app.sqlite          │
  │  tiles.yaml ──┐    │   docker pause    │   (heimdall_config volume)        │
  │  tofu output ─┴─►  │   docker cp out   │                                   │
  │   sqlite3 edit ◄───┼───────────────────┤   ◄── cp in + chown abc:abc       │
  │   (stdlib)         │   docker unpause  │                                   │
  └────────────────────┘                   └──────────────────────────────────┘
        all DB logic in Python                Heimdall re-reads items live (~3s)
        unit-testable in --db mode            → tiles appear on next page load
```

The CLI runs **locally**. It resolves the server VM, briefly pauses the Heimdall container,
copies `app.sqlite` out, mutates it with Python's stdlib `sqlite3`, copies it back, restores
ownership, and unpauses. **No container restart is required** — Heimdall reads the `items`
table on every page load.

## Data model

Heimdall's whole model lives in **one table differentiated by a `type` column**, plus a pivot.

### `items` table

Tiles, tags, and the dashboard root are all rows here.

| Column | Notes |
|--------|-------|
| `id` | integer PK, autoincrement |
| `title` | **required**; also our idempotency key |
| `url` | **required** |
| `colour` | nullable; tile colour, e.g. `#161b1f` (British spelling) |
| `icon` | nullable; path like `icons/<file>.png` — the file must exist on disk (see Gotchas) |
| `description` | nullable; user text for plain tiles. **Overloaded**: enhanced apps store serialized JSON config here — we leave it empty |
| `pinned` | bool, default `0`; `1` = shown on the pinned dashboard |
| `order` | integer, default `0`; sort order |
| `type` | **`0` = tile, `1` = tag/category** |
| `class` | nullable; PHP class for enhanced apps — we leave NULL |
| `appid` | nullable; links to the supported-app catalog — we leave NULL |
| `user_id` | default `1` (single-user); part of our idempotency key |
| `created_at` / `updated_at` | timestamps |
| `deleted_at` | nullable; **soft delete** — the UI "delete" sets this, it does not hard-delete |

### `item_tag` pivot — the critical, counter-intuitive part

Maps dashboards (tags) → tiles. **Both FKs point at `items`.** The semantics are inverted:

- `item_id` = the **parent tag**, `tag_id` = the **child tile**.
- **Tag `0` is the default dashboard** — a virtual root that is *not* a stored row.
- **To make a tile visible on the home dashboard you MUST insert `item_tag (item_id=0,
  tag_id=<new item id>)`.** Inserting into `items` alone produces an invisible tile.
- To place a tile under a custom category, create a tag row (`items.type=1`) and use *its* id
  as `item_id`.

### Plain vs enhanced apps

We model **every monitoring tile as a plain/custom tile**: `type=0`, `appid=NULL`,
`class=NULL`, `description=''`. The `icon` may point at a Foundation icon path for a logo, but
no live-stats integration. **Enhanced apps** (Plex/Sonarr-style, with API keys serialized into
`description`) are **out of scope**.

## CLI design

A uv single-file script at `clusters/centralized_monitoring/scripts/heimdall_cli.py`:

```python
#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml"]
# ///
```

Everything else (`sqlite3`, `argparse`, `subprocess`, `json`, `tempfile`, `shutil`) is stdlib.

### Subcommands (argparse)

| Command | Purpose |
|---------|---------|
| `add --title T --url U [--icon I --colour C --tag G --pinned]` | Idempotent upsert of one tile. |
| `remove --title T [--tag G] [--hard]` | Soft-delete by default (`deleted_at=now`); `--hard` for real `DELETE`. |
| `list [--json]` | Show current tiles (`WHERE deleted_at IS NULL`). |
| `sync --config tiles.yaml [--prune]` | Reconcile the DB to the config. `--prune` soft-deletes managed tiles absent from the config (never touches hand-added tiles — see managed marker). |
| `generate --from-tofu [--chdir DIR] [-o tiles.yaml]` | Emit a `tiles.yaml` from `tofu output -json` (`server_ipv4` + `enable_*` flags + the endpoints catalog). |
| `seed --compose-file F --server-ip IP --enabled "f1,f2" [--prune]` | On-host catalog seed (the cloud-init path). No tofu, no config: builds tiles from `build_catalog_tiles` and reconciles via the **local-docker** transport. See *Cloud-init auto-seed*. |

### Global flags

| Flag | Default | Purpose |
|------|---------|---------|
| `--vm` / `--instance` | `centralized-monitoring-server` | Multipass instance hosting Heimdall. |
| `--container` | `heimdall` | Docker container/service name. |
| `--user-id` | `1` | Heimdall user the tiles belong to. |
| `--db PATH` | — | **Local mode**: operate directly on a local `app.sqlite` (no Docker/SSH). The seam that makes the logic unit-testable. |
| `--dry-run` | off | Print the SQL/plan without writing. |

### Idempotency contract

For every upsert:

```sql
SELECT id FROM items WHERE title = ? AND user_id = ? AND deleted_at IS NULL;
-- present → UPDATE that row's url/colour/icon/order
-- absent  → INSERT a new items row (type=0, appid/class NULL, description '')
-- then ALWAYS ensure the pivot exists:
INSERT INTO item_tag (item_id, tag_id, created_at, updated_at)
SELECT 0, :id, datetime('now'), datetime('now')
WHERE NOT EXISTS (SELECT 1 FROM item_tag WHERE item_id = 0 AND tag_id = :id);
```

Open the DB with `PRAGMA busy_timeout = 5000` and probe columns with `PRAGMA table_info(items)`
before assuming `appid`/`appdescription` exist (they are 2.x+ only).

### Managed marker

So `sync --prune` never deletes a tile a human added in the UI, the tool tags everything it
creates as **managed**. Recommended implementation: a dedicated tag item (`items.type=1`,
`title="managed-by-cli"`) and an `item_tag` association from each managed tile to it. `--prune`
only soft-deletes tiles that carry the managed association and are absent from the config.

## Config schema (`tiles.yaml`)

Committed at `clusters/centralized_monitoring/heimdall/tiles.yaml`. A single list of tiles:

```yaml
tiles:
  - title: Grafana
    url: "http://{server_ip}:3000"
    icon: grafana             # optional: Foundation icon name or path under /config/www/icons
    colour: "#161b1f"
    tag: Monitoring           # optional; omit → default dashboard (tag 0)
    enabled_when: enable_grafana   # optional flag gate honored by `generate`
```

- `{server_ip}` (and similar placeholders) are substituted from tofu outputs at sync time.
- `enabled_when` lets `generate --from-tofu` drop tiles whose `enable_*` flag is off.

### Default generated tile set

Sourced from [`clusters/centralized_monitoring/docs/endpoints.md`](../clusters/centralized_monitoring/docs/endpoints.md)
(the authoritative catalog) — the human-facing UIs, each gated by its flag:

| Title | URL | Flag gate |
|-------|-----|-----------|
| Grafana | `http://{server_ip}:3000` | always (spine) |
| Prometheus | `http://{server_ip}:9090` | always (spine) |
| Alertmanager | `http://{server_ip}:9093` | always (spine) |
| OpenObserve | `http://{server_ip}:5080` | `enable_openobserve` |
| Uptime Kuma | `http://{server_ip}:3001` | `enable_uptime_kuma` |
| Traefik dashboard | `http://{server_ip}:8082` | `enable_traefik` |

Exporters (blackbox `:9115`, node `:9100`, cAdvisor `:8080`, statsd, ssh, k0s bundle…) are
**not** generated by default — they expose `/metrics`, not human dashboards. They remain easy
to add by hand in `tiles.yaml` if wanted.

## `docker cp` write path

The remote-mode mutation sequence (each shell step routed through `rtk` per repo convention):

1. **Resolve** server IP/VM from `tofu output -json` (`server_ipv4` / `hosts`), or accept
   `--vm`.
2. **Pause** Heimdall to avoid a single-writer lock:
   `multipass exec <vm> -- docker compose pause heimdall` (fallback `docker pause heimdall`).
3. **Copy out:** `docker cp heimdall:/config/www/app.sqlite` → a local temp file.
4. **Mutate** the temp file with Python `sqlite3` (the same code path as `--db` local mode).
5. **Copy in:** `docker cp <temp> heimdall:/config/www/app.sqlite`.
6. **Fix ownership:** `docker exec heimdall chown abc:abc /config/www/app.sqlite`
   (linuxserver images run as the `abc`/PUID user).
7. **Unpause:** `docker compose unpause heimdall`. No restart needed; tiles appear on next page
   load.

`--db PATH` short-circuits steps 1–3, 5–7 and runs only step 4 against a local file — the
testing seam.

## Justfile integration

New recipes in the root `Justfile`, mirroring the existing folder-name parametrization
(`replace(CLUSTER, "_", "-")` to derive the VM name), all run through `uv run`:

```make
heimdall-sync CLUSTER:      # generate from tofu, then sync --prune
heimdall-list CLUSTER:
heimdall-add  CLUSTER TITLE URL:
heimdall-rm   CLUSTER TITLE:
```

`heimdall-sync` is the headline recipe: `generate --from-tofu` then `sync --prune`, so a single
command reconciles Heimdall to the live, flag-aware endpoint set.

## Cloud-init auto-seed

`heimdall_config` is destroyed on every `just destroy`, so the laptop recipes would have to be
re-run after each `just up`. Instead the server VM **seeds itself at first boot**, so `just up`
alone yields a populated dashboard. Gated by **both** `enable_heimdall` and the new
`enable_heimdall_seed` (default `true`; opt out to manage tiles by hand).

How it wires together (all in `clusters/centralized_monitoring/`):

- **`main.tf`** passes three things into the `server.yaml.tftpl` templatefile: the script body
  (`heimdall_cli_py = file("scripts/heimdall_cli.py")`), the enabled-flag list
  (`heimdall_seed_flags = join(",", local.enabled_exporters)`), and `enable_heimdall_seed`.
  The flag list is computed at render time (tofu knows it); the **server IP is not** (it is a
  computed attribute), so it is discovered at runtime instead.
- **`cloud-init/server.yaml.tftpl`** (gated `%{ if enable_heimdall && enable_heimdall_seed ~}`):
  writes `/opt/stack/heimdall/heimdall_cli.py`, then in `runcmd` after `docker compose up -d`:
  1. install uv: `curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh`
  2. wait (bounded) for the DB: `until docker compose -f /opt/stack/compose.yaml exec -T heimdall test -f /config/www/app.sqlite`
  3. discover the primary IP (avoiding `docker0`): `IP=$(ip -4 route get 1.1.1.1 | awk '{print $7; exit}')`
  4. seed: `uv run /opt/stack/heimdall/heimdall_cli.py seed --compose-file /opt/stack/compose.yaml --server-ip "$IP" --enabled "${heimdall_seed_flags}" --prune`
  Every step is `|| true` — a seed hiccup never fails the boot.
- **`seed`** uses the **local-docker transport** (`docker compose -f … pause/cp/exec`) because
  on the VM there is no ssh and no stable `container_name` — only the **service** name
  `heimdall` is reliable. It builds tiles from the same `build_catalog_tiles()` the headline
  `just heimdall-sync` uses, so boot-time and laptop seeding produce identical dashboards.

Because `just destroy`/`up` recreates the VM, cloud-init (and thus the seed) re-runs on every
bring-up; `--prune` keeps the dashboard converged to the flag-aware set without duplicates.

## Testing strategy

Mirrors the cluster's two-layer split (see `CLAUDE.md`).

### Hermetic (pytest, no VMs) — `tests/heimdall/test_heimdall_cli.py`

Build a fixture `app.sqlite` with the real schema (or a trimmed migration) and exercise the CLI
in `--db` mode:

- `add` creates an `items` row **and** the `item_tag (0, id)` pivot row.
- `add` is **idempotent** — a second identical `add` produces no duplicate row.
- `remove` sets `deleted_at` (soft delete); `--hard` removes the row.
- `sync --prune` removes only **managed** tiles absent from the config, never hand-added ones.
- `generate --from-tofu` honors `enable_*` flags (a disabled service yields no tile).
- `list` filters `deleted_at IS NULL`.

### Live (testinfra) — `tests/testinfra/test_heimdall.py`

After `just up` + `just heimdall-sync`, reuse the SSH fixtures in
`tests/testinfra/conftest.py` to assert the expected tiles exist — e.g.
`docker exec heimdall sqlite3 /config/www/app.sqlite "SELECT title FROM items WHERE deleted_at
IS NULL"` (or scrape the rendered HTML) returns Grafana/Prometheus/Alertmanager/etc.

## Quickstart

```sh
just up   centralized_monitoring          # provision VMs + docker stack (Heimdall empty)
just heimdall-sync centralized_monitoring # generate from tofu outputs + sync into Heimdall
open "http://$(tofu -chdir=clusters/centralized_monitoring output -raw server_ipv4)/"
```

Freeform examples:

```sh
just heimdall-add centralized_monitoring "Grafana" "http://<server>:3000"
just heimdall-list centralized_monitoring
just heimdall-rm  centralized_monitoring "Grafana"
```

## Gotchas

- **`item_tag (0, id)` is mandatory** — a tile with no pivot row is invisible on the home
  dashboard.
- **Soft deletes** — always filter `deleted_at IS NULL` in existence checks or idempotency
  breaks (deleted titles look "present").
- **DB lock** — SQLite is single-writer; pause the container (or rely on `busy_timeout`) while
  writing. Heimdall reads `app.sqlite` ~every 3s.
- **Icons live on disk** — the `icon` column is a path; the file must exist under
  `/config/www/icons/` and be owned by `abc`. Foundation logos may need to be copied in.
- **Schema version coupling** — `appid`/`appdescription` columns are 2.x+; probe with
  `PRAGMA table_info(items)` rather than hardcoding.
- **Volume lifecycle** — `heimdall_config` is destroyed on `just destroy`. With auto-seed on
  (default) every `just up` re-seeds; otherwise re-run `just heimdall-sync` after each `just up`.
- **Traefik routing** — when `enable_traefik` is on, Heimdall is fronted at `heimdall.localhost`
  rather than `:80`; tile URLs still point at the *target* services, not at Heimdall.

## Future work

- Add a **Heimdall URL to `outputs.tf` `shell_hints`** (currently missing).
- Optional **enhanced-app tiles** (live stats) for services that support it.
- **Reuse the tool for other clusters** — it is cluster-agnostic apart from the default tile
  catalog; parametrize the catalog per cluster.
