You are the "unifi" research agent in a documentation fleet for the multipass-lab repo (cwd is
already the repo root). Work fully autonomously — no clarifying questions, just finish the job.
This is a READ-ONLY research job: do not edit any file except the one fact-sheet output file below.

Read, in full or in relevant part:
- `clusters/centralized_unifi/README.md`
- `clusters/centralized_unifi/variables.tf`
- `clusters/centralized_unifi/outputs.tf`
- `specs/centralized_unifi.md`

Verify every file path you plan to cite actually exists (Read/ls it — don't guess).

Write `.team/docs-fleet/unifi.factsheet.md` with this exact structure:

```markdown
# Fact sheet: centralized_unifi

**One-liner:** <one sentence — this cluster emulates a UniFi Cloud Key controller +
USG log-shipping pipeline, no human dashboards, log-pipeline only>

**VMs:**
| VM role | Count | Sizing | Purpose |
|---|---|---|---|
<rows for `controller` (syslog-ng collector) and `usg` (rsyslog forwarder, emulated amd64), sizing from variables.tf defaults>

**Existing docs (confirmed to exist on disk):**
- `clusters/centralized_unifi/README.md` (only cluster-level doc — no USAGE.md, no TUTORIAL.md, no docs/ dir)

**Specs:**
- `specs/centralized_unifi.md` — the only spec covering this cluster

**web_urls / core dashboards (from outputs.tf):**
State explicitly: `core` is empty — this is a log-pipeline-only cluster with no human-facing
dashboard; `all` exposes the enabled `/metrics` exporter endpoints (node_exporter on both VMs,
syslog_ng_exporter on the controller) — list exact ports.

**Notes for the doc authors:**
<anything else worth knowing — e.g. this cluster is currently INVISIBLE in CLAUDE.md (no mention
anywhere at all — not the "## Clusters" sentence, not any later paragraph), so the CLAUDE.md
author will need to write its clause from scratch with no existing prose to anchor tone from
other than the sibling clusters' style>
```

When done, print a short confirmation to stdout, then stop.
