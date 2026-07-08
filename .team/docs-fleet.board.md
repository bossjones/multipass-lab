# docs-fleet — TEAM BOARD

**FSM:** `DONE` 🟢  ·  **target:** backfill CLAUDE.md / README.md / docs/README.md for
centralized_{k0s,pki,unifi,netbox,dns}; fix stale status banner in specs/centralized_k0s.md
**Reviewer verdict: PASS, no fixes required.**

`git diff --stat`: CLAUDE.md +8/-2 · README.md +25 · docs/README.md +120/-2 · specs/centralized_k0s.md +13/-5

| agent | emoji | state | last log |
|-------|-------|-------|----------|
| 👑 lead        | 🔵 | working | all 5 Phase A researchers launched (surfaces 24-28), waiting for fact sheets |
| 🌀 k0s         | 🔵 | working | reading spec + board, will fix status banner then emit fact sheet |
| 🔐 pki         | 🔵 | working | reading README/USAGE/DEFAULT_PASSWORDS + specs |
| 📡 unifi       | 🔵 | working | reading README + variables/outputs + spec |
| 📦 netbox      | 🔵 | working | reading variables/outputs + 4 specs |
| 🌐 dns         | 🔵 | working | reading README/USAGE/DEFAULT_PASSWORDS + 4 specs |
| 📄 claude-md-author     | 🟢 | done | added k0s/pki/unifi clauses to "## Clusters"; +8/-2, verified scoped |
| 📖 readme-author        | 🟢 | done | 5 new Labs rows + 20 Further-reading bullets, all 20/20 links verified on disk |
| 🗺️ docs-readme-author   | 🟢 | done | 5 new Labs subsections + 21 Documentation-map rows |
| 🔍 reviewer    | 🟢 | done | PASS on all 4 checks (links/sizing/consistency/richness); no fixes needed |

Legend: 🔵 working · 🟢 done · 🔴 error · ⚪ queued

## Phase A — fact sheets (research, disjoint files)
Each researcher writes `.team/docs-fleet/<cluster>.factsheet.md`. The k0s researcher additionally
fixes `specs/centralized_k0s.md`'s stale status banner directly (own file, no collision).

## Phase B — shared-file authoring (one owner per file)
- claude-md-author → `CLAUDE.md` "## Clusters" (add k0s/pki/unifi clauses only)
- readme-author → `README.md` Labs table + Further reading
- docs-readme-author → `docs/README.md` Labs subsections + Documentation map

## Phase C — review
- reviewer → read-only pass over the 4 changed files + original sources; findings appended below.

## Review findings

**Verdict:** PASS

### 1. Link resolution
**PASS.** Checked all 20 new relative-link targets in `README.md` (root-relative), all 20 new
targets in `docs/README.md` (`../`-relative, incl. the one link not present in README.md:
`../specs/centralized_k0s/build-plans/`), and the 6 links touched/added in `specs/centralized_k0s.md`'s
status banner (`../clusters/centralized_k0s/`, `../clusters/centralized_k0s/docs/feature-flags.md`,
`centralized_k0s/build-plans/{core,k0sctl,node,vector-tests}.md`) — every target resolves with
`test -e` from its linking file's directory. No broken links found.

### 2. VM counts/sizing accuracy
**PASS.** Cross-checked all 5 clusters' README.md Labs-table VM counts and docs/README.md
per-cluster sizing tables against each cluster's `variables.tf` defaults:
- **k0s**: 3 VMs (README) = `k0s_control_plane_count=1` + `worker_count=2`; docs table sizing
  (controller 3vCPU/3G/20G, worker 2vCPU/4G/30G, haproxy 1vCPU/1G/10G opt-in) matches
  `controller_size`/`worker_size`/`haproxy_size` defaults exactly.
- **pki**: 2 VMs; docs table (ca 1vCPU/1G/10G, services 2vCPU/4G/25G) matches `var.ca`/`var.services`.
- **unifi**: 2 VMs; docs table (usg 2vCPU/2G/15G, controller 2vCPU/2G/20G) matches `var.usg`/`var.controller`.
- **netbox**: 2 VMs (server+client; `agent` correctly excluded from the count as opt-in
  `enable_discovery`, consistent with the base-cluster convention used elsewhere); docs table
  (server 2vCPU/4G/20G, client 1vCPU/1G/10G, agent 1vCPU/1G/10G opt-in) matches `var.server`/`var.client`/`var.agent`.
- **dns**: 1 VM; docs table (server 2vCPU/2G/20G) matches `var.server`.

No mismatches found.

### 3. No stale/contradictory claims
**PASS.**
- `centralized_k0s`, `centralized_unifi`, `centralized_netbox` correctly documented as having no
  dedicated README/USAGE (k0s: no README/USAGE at top level; unifi: has README.md but no
  USAGE.md/docs/; netbox: no README/USAGE/docs) — verified via `ls`; docs/README.md's
  "(no dedicated README/USAGE yet...)" / "(no USAGE.md or docs/ dir yet...)" annotations are accurate.
  `pki` and `dns` correctly documented as having README+USAGE+DEFAULT_PASSWORDS (all confirmed present).
- The k0s status banner's test claims (`just check` 9/9, `just verify` 26 passed / 25 skipped /
  0 failed, "no live patches") match `.team/centralized_k0s.board.md` verbatim.
- CLAUDE.md's new k0s/pki/unifi clauses read grammatically as part of the existing "The clusters
  are ..." enumeration sentence — it still terminates correctly ("...and `clusters/centralized_unifi/`
  (...; see `specs/centralized_unifi.md`). `centralized_dns` is a **cross-cluster hub...").
  **Minor technicality:** the diff is not purely additive — two existing lines were touched
  (`and clusters/centralized_dns/` → `clusters/centralized_dns/`, and the dns clause's closing
  `).` → `),`) to graft the 3 new clauses into the middle of the list instead of appending after
  dns. This is a mechanical punctuation/conjunction edit required by the list restructuring, not a
  content change to the netbox/dns wording itself — the descriptive text for both clusters is
  byte-identical. Not a real defect, just worth noting since the task explicitly asked to check for
  "only insertions."

### 4. Markdown richness
**PASS.** README.md's 5 new Labs-table rows and 20 new Further-reading bullets use the same
`emoji [text](path)` link convention as the existing rows/bullets (🚩📐📘📖🔑🔀🤝🛠️🌱🔍🧷📊 etc.,
no bare bullets or plain-text links). docs/README.md's 5 new subsections (`centralized_k0s`,
`centralized_pki`, `centralized_unifi`, `centralized_netbox`, `centralized_dns`) each include a
prose intro, a real `| VM | Role | Sizing |` table (not just prose), and a closing **Docs:** line
with emoji-linked references — matching the shape of the existing `centralized_logging` /
`centralized_monitoring` subsections.

### Summary
All four checks pass cleanly; no broken links, no VM/sizing mismatches, no stale or contradictory
claims, and markdown formatting matches existing conventions throughout. The only item worth a
second look is the CLAUDE.md diff touching two lines of existing text for grammatical necessity
(removing a now-mid-list "and", adjusting closing punctuation) rather than being pure insertions —
this is cosmetic/expected and requires no fix. No concrete fixes are needed before this work is
considered done.
