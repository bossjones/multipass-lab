You are the "readme-author" agent in a documentation fleet for the multipass-lab repo (cwd is
already the repo root). Work fully autonomously — no clarifying questions, just finish the job.
You are the SOLE owner of the root `README.md` for this task — no other agent will touch it, so
make one clean, complete pass.

## Read first

- All 5 fact sheets: `.team/docs-fleet/{k0s,pki,unifi,netbox,dns}.factsheet.md`
- The current root `README.md` in full, especially its "## Labs" section (a markdown table with
  columns `Lab | What it demonstrates | VMs | Docs`) and its "## Further reading" section near the
  bottom (a flat bullet list, each bullet an emoji + a markdown link + a short description).

## What to do

### 1. Add 5 rows to the "## Labs" table

One row each for `centralized_k0s`, `centralized_pki`, `centralized_unifi`, `centralized_netbox`,
`centralized_dns`, matching the EXISTING table's exact style:
- **Lab** column: bold cluster name, e.g. `**centralized_k0s**`
- **What it demonstrates** column: a rich one-to-two sentence description (pull from each fact
  sheet's one-liner + notable details — VM roles, key tech, any caveat worth surfacing)
- **VMs** column: the VM count (use the DEFAULT topology count where a cluster has an opt-in
  larger mode, e.g. k0s = 3, not 7)
- **Docs** column: the SAME emoji-link convention already used in the existing rows — 📘 for
  USAGE.md, 📖 for README.md, 🧭 for TUTORIAL.md, 📐 for the main spec, 📚 for a docs/ directory,
  and reuse/invent a sensible new emoji for extra specs not already covered by the convention
  (e.g. the existing rows already use 📊 for a metrics spec and 🧪 for an e2e spec — follow that
  precedent, pick a fitting emoji per doc rather than reusing 📐 for everything). ONLY link docs
  a fact sheet confirmed actually exist for that cluster — several clusters have NO README/USAGE
  (say so in the fact sheet), so those columns will legitimately be shorter for those rows. Every
  link must be a real relative path from the repo root (e.g. `specs/centralized_pki.md`,
  `clusters/centralized_pki/README.md`) — do not invent a path.

### 2. Add matching bullets to "## Further reading"

For every doc you just linked in the Labs table (and any other doc the fact sheets flagged as
existing and worth surfacing, e.g. multiple specs per cluster), add a bullet in the same
emoji + `[path](path)` + short description style as the existing bullets, inserted in a sensible
place (grouped near where similar clusters' bullets already sit, keeping the existing bullets
for centralized_logging/centralized_monitoring untouched and in their current position).

### 3. Leave everything else in the file untouched

Do not modify the "Why this exists," "Quickstart," "How it works," "Repository layout," or
"Toolchain" sections.

## When done

Print a short confirmation to stdout showing exactly what you added (list the 5 new table rows'
first column + a count of new Further-reading bullets), then stop.
