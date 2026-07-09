You are the "netbox" research agent in a documentation fleet for the multipass-lab repo (cwd is
already the repo root). Work fully autonomously — no clarifying questions, just finish the job.
This is a READ-ONLY research job: do not edit any file except the one fact-sheet output file below.

Read, in full or in relevant part:
- `clusters/centralized_netbox/variables.tf`
- `clusters/centralized_netbox/outputs.tf`
- `specs/centralized_netbox.md`
- `specs/cli-netbox.md`
- `specs/netbox-data.md`
- `specs/netbox-discovery.md`
- Also `ls clusters/centralized_netbox/` to confirm there is genuinely no README.md/USAGE.md/docs/ dir.

Verify every file path you plan to cite actually exists (Read/ls it — don't guess).

Write `.team/docs-fleet/netbox.factsheet.md` with this exact structure:

```markdown
# Fact sheet: centralized_netbox

**One-liner:** <one sentence — a NetBox DCIM/IPAM server + a client VM that self-registers via
the REST API on first boot, with an opt-in discovery agent>

**VMs:**
| VM role | Count | Sizing | Purpose |
|---|---|---|---|
<rows for `server`, `client`, and opt-in `agent` (count-gated on enable_discovery), sizing from variables.tf defaults>

**Existing docs (confirmed to exist on disk):**
State explicitly: this cluster has NO `README.md`, NO `USAGE.md`, NO `docs/` directory — only
`scripts/` (the netbox_cli.py verification CLI) and `tests/`.

**Specs:**
- `specs/centralized_netbox.md` — main design spec
- `specs/cli-netbox.md` — the `netbox_cli.py` verification CLI design
- `specs/netbox-data.md` — base data-model seed design
- `specs/netbox-discovery.md` — opt-in Diode/orb-agent discovery design

**web_urls / core dashboards (from outputs.tf):**
<summarize — NetBox UI on some port, `/api/`, enabled exporters, Netdata, Diode ingress URL when
discovery is on — list exact ports/paths>

**Notes for the doc authors:**
<anything else worth knowing — e.g. this cluster is ALREADY correctly covered in CLAUDE.md's
"## Clusters" enumeration sentence and its own dedicated paragraph, so the CLAUDE.md author
should make NO change for netbox — only README.md and docs/README.md need new entries>
```

When done, print a short confirmation to stdout, then stop.
