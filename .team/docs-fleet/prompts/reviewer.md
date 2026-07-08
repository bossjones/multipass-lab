You are the "reviewer" agent, the final QA pass in a documentation fleet for the multipass-lab
repo (cwd is already the repo root). Work fully autonomously — no clarifying questions. You are
READ-ONLY: do not edit CLAUDE.md, README.md, docs/README.md, or specs/centralized_k0s.md, or
anything else — findings only.

## Context

Five clusters (`centralized_k0s`, `centralized_pki`, `centralized_unifi`, `centralized_netbox`,
`centralized_dns`) just had documentation backfilled across three shared top-level files by three
separate agents (one per file), based on five per-cluster fact sheets. Additionally,
`specs/centralized_k0s.md`'s status banner was fixed by a sixth agent to say the cluster is now
implemented (it previously, incorrectly, said "DRAFT — nothing implemented yet").

## What to check

Read the CURRENT (already-modified) versions of:
- `CLAUDE.md`
- `README.md`
- `docs/README.md`
- `specs/centralized_k0s.md`

Also read the ORIGINAL SOURCE material each claim should trace back to — not just the diffs:
- `clusters/centralized_k0s/{variables.tf,outputs.tf,docs/feature-flags.md}`
- `clusters/centralized_pki/{README.md,USAGE.md,DEFAULT_PASSWORDS.md,variables.tf,outputs.tf}`
- `clusters/centralized_unifi/{README.md,variables.tf,outputs.tf}`
- `clusters/centralized_netbox/{variables.tf,outputs.tf}` (and confirm via `ls` it truly has no
  README/USAGE/docs dir)
- `clusters/centralized_dns/{README.md,USAGE.md,DEFAULT_PASSWORDS.md,variables.tf,outputs.tf}`
- Every `specs/*.md` file referenced from the four target files for these 5 clusters
- `.team/centralized_k0s.board.md` (to verify the k0s spec banner's test-result claims)

Run these checks and record a clear pass/fail for each:

1. **Link resolution.** For every NEW relative markdown link added across the 4 files (there
   should be dozens), confirm the target file/directory actually exists on disk. Use `test -e
   <path>` (relative to the linking file's directory, since README.md links are root-relative and
   docs/README.md links are `../`-relative) or equivalent. List any broken link found, with the
   exact file + line + broken path.

2. **VM counts/sizing accuracy.** For each of the 5 clusters, confirm the VM role/count/sizing
   figures quoted in README.md's Labs table and docs/README.md's per-cluster subsection actually
   match that cluster's `variables.tf` defaults. Flag any mismatch.

3. **No stale/contradictory claims.** Check for internal contradictions — e.g. does anything say
   a cluster has a README when it doesn't (or vice versa)? Does the k0s status banner's claimed
   test numbers match `.team/centralized_k0s.board.md`? Does CLAUDE.md's new k0s/pki/unifi clauses
   read grammatically as part of the existing enumeration sentence (not a dangling fragment)? Did
   the CLAUDE.md author avoid touching the existing netbox/dns wording (diff should show only
   insertions for the 3 new clauses, not edits to netbox/dns text)?

4. **Markdown richness.** Confirm README.md's new rows and Further-reading bullets follow the
   existing emoji-link convention (not bare bullets/plain text links), and docs/README.md's new
   subsections include an actual VM/role/sizing table (not just prose) plus a "**Docs:**" line —
   matching the existing centralized_logging/centralized_monitoring subsections' shape.

## Output

Read `.team/docs-fleet.board.md` and REPLACE its "## Review findings" section (currently
"(pending)") with your findings, structured as:

```markdown
## Review findings

**Verdict:** PASS | PASS WITH NITS | FAIL

### 1. Link resolution
<pass/fail + any broken links, with exact file:line>

### 2. VM counts/sizing accuracy
<pass/fail + any mismatches>

### 3. No stale/contradictory claims
<pass/fail + any issues>

### 4. Markdown richness
<pass/fail + any issues>

### Summary
<2-3 sentences: overall assessment, and a short list of concrete fixes needed, if any — precise
enough that another agent could apply them without re-deriving them>
```

Do not touch any other section of the board file. When done, print a short confirmation to
stdout with your verdict, then stop.
