You are the "k0s" research agent in a documentation fleet for the multipass-lab repo
(you are running with cwd already at the repo root). Work fully autonomously — do not ask
clarifying questions, just do the work and finish.

## Your two jobs

### Job 1 — fix the stale status banner in `specs/centralized_k0s.md`

Read `specs/centralized_k0s.md` in full, and also read `.team/centralized_k0s.board.md`
(this shows the build is actually DONE: `just check` 9/9, `just verify` 26 passed/25 skipped/0
failed, FSM DONE). The spec's current banner (near the top, right after the H1) says something
like "Status: DRAFT — hardened after an adversarial review round... Nothing is implemented yet."
That is now WRONG — the cluster is fully implemented and verified.

Edit ONLY that status banner blockquote. Replace it with a banner that:
- States the cluster is now IMPLEMENTED and verified (cite the check/verify numbers from the board).
- Links forward, using real relative markdown links (verify each file exists before linking, with
  Read or ls — do not guess), to:
  - `clusters/centralized_k0s/` (the implementation)
  - `clusters/centralized_k0s/docs/feature-flags.md`
  - `specs/centralized_k0s/build-plans/core.md`
  - `specs/centralized_k0s/build-plans/k0sctl.md`
  - `specs/centralized_k0s/build-plans/node.md`
  - `specs/centralized_k0s/build-plans/vector-tests.md`
- Keeps the same tone/register as the rest of the file (terse, technical, adversarial-review-aware).
- Do NOT touch anything else in the file — not the Context/Objective/Architecture sections, nothing.

### Job 2 — emit a fact sheet

Read `clusters/centralized_k0s/variables.tf`, `clusters/centralized_k0s/main.tf`,
`clusters/centralized_k0s/outputs.tf`, `clusters/centralized_k0s/docs/feature-flags.md`.

Write `.team/docs-fleet/k0s.factsheet.md` with this exact structure:

```markdown
# Fact sheet: centralized_k0s

**One-liner:** <one sentence describing what this cluster demonstrates>

**VMs:**
| VM role | Count | Sizing | Purpose |
|---|---|---|---|
<one row per role, from variables.tf defaults — note the default topology is 1 controller +
2 workers + no haproxy (3 VMs total), and an HA opt-in is 3 controllers + 3 workers + 1 haproxy>

**Existing docs (confirmed to exist on disk — do not list anything you have not verified):**
- <list each with its relative path, e.g. `clusters/centralized_k0s/docs/feature-flags.md`>
- Note explicitly: NO `README.md` or `USAGE.md` exists for this cluster yet.

**Specs:**
- `specs/centralized_k0s.md` — main design spec (status banner just fixed by this agent)
- `specs/centralized_k0s/build-plans/{core,k0sctl,node,vector-tests}.md` — build-plan shards

**web_urls / core dashboards (from outputs.tf):**
<summarize what `web_urls` exposes, if anything — this cluster may have none in "core">

**Notes for the doc authors:**
<anything else worth knowing when writing the README.md Labs-table row and docs/README.md
subsection — e.g. this is the newest cluster on this branch, no HA by default, etc.>
```

When both jobs are done, print a short confirmation to stdout summarizing what you changed, then stop.
