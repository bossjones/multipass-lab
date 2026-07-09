You are the "docs-readme-author" agent in a documentation fleet for the multipass-lab repo (cwd
is already the repo root). Work fully autonomously — no clarifying questions, just finish the job.
You are the SOLE owner of `docs/README.md` for this task — no other agent will touch it, so make
one clean, complete pass.

## Read first

- All 5 fact sheets: `.team/docs-fleet/{k0s,pki,unifi,netbox,dns}.factsheet.md`
- The current `docs/README.md` in full, especially its "## Documentation map" table (near the top,
  two columns: `Doc | What's here`) and its "## Labs" section near the bottom (one
  `### centralized_<name>` subsection per cluster today: `centralized_logging`,
  `centralized_monitoring` — each has a short paragraph, a VM/role/sizing markdown table, and a
  "**Docs:**" line using an emoji + markdown-link convention).

## What to do

### 1. Add 5 "### centralized_<name>" subsections under "## Labs"

One each for `centralized_k0s`, `centralized_pki`, `centralized_unifi`, `centralized_netbox`,
`centralized_dns`, mirroring the EXACT structure of the existing `centralized_logging`/
`centralized_monitoring` subsections:
- A short prose paragraph (2-3 sentences) describing what the lab demonstrates — pull from each
  fact sheet's one-liner plus any standout detail (e.g. no-HA-by-default for k0s, log-pipeline-only
  for unifi, opt-in discovery for netbox, cross-cluster hub role for dns, fleet-edge Traefik for
  pki).
- A markdown table of VM role → purpose → sizing (mirror the existing tables' column style;
  `| VM | Role | Sizing |` or similar — match whatever the existing two subsections use exactly).
- A "**Docs:**" line using the same emoji + `[label](relative/path)` · -separated convention as
  the existing subsections — ONLY link docs a fact sheet confirmed actually exist. Several
  clusters have no README/USAGE/docs dir — say so plainly in the subsection text rather than
  omitting silently, e.g. "(no dedicated README/USAGE yet — see the spec below)".

Insert them in a sensible order (e.g. after the existing two, or grouped logically — your call,
just be consistent), and update the closing note ("_New labs land as new `clusters/<name>/`
folders..._") if it references a specific list that's now out of date.

### 2. Add 5 rows to the "## Documentation map" table

One row per new doc surfaced (each cluster likely contributes multiple rows — its main spec at
minimum, plus README/USAGE/feature-flags/extra specs where they exist), in the table's existing
two-column format, following the existing rows' emoji + link + description style.

### 3. Leave everything else in the file untouched

Do not modify the mermaid flowchart, "## Quickstart," or anything about `centralized_logging`/
`centralized_monitoring`'s existing subsections/rows.

## When done

Print a short confirmation to stdout showing exactly what you added (the 5 new subsection
headings + a count of new Documentation-map rows), then stop.
