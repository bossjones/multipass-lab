You are the "dns" research agent in a documentation fleet for the multipass-lab repo (cwd is
already the repo root). Work fully autonomously — no clarifying questions, just finish the job.
This is a READ-ONLY research job: do not edit any file except the one fact-sheet output file below.

Read, in full or in relevant part:
- `clusters/centralized_dns/README.md`
- `clusters/centralized_dns/USAGE.md`
- `clusters/centralized_dns/DEFAULT_PASSWORDS.md`
- `clusters/centralized_dns/variables.tf`
- `clusters/centralized_dns/outputs.tf`
- `specs/centralized_dns.md`
- `specs/cross-cluster.md`
- `specs/pki-and-dns.md`
- `specs/dns-dashboards.md`

Verify every file path you plan to cite actually exists (Read/ls it — don't guess). Note
`specs/dns-dashboards.md` may be marked "planned"/not-yet-built status — check and note that if so.

Write `.team/docs-fleet/dns.factsheet.md` with this exact structure:

```markdown
# Fact sheet: centralized_dns

**One-liner:** <one sentence — a single VM running AdGuard Home over a recursive Unbound
resolver, the network-wide ad-blocking DNS resolver AND a cross-cluster hub that comes up
FIRST in `just up-connected`>

**VMs:**
| VM role | Count | Sizing | Purpose |
|---|---|---|---|
<row for `server`, sizing from variables.tf defaults>

**Existing docs (confirmed to exist on disk):**
- `clusters/centralized_dns/README.md`
- `clusters/centralized_dns/USAGE.md`
- `clusters/centralized_dns/DEFAULT_PASSWORDS.md`
(only list ones you actually confirmed exist)

**Specs:**
- `specs/centralized_dns.md` — main design spec
- `specs/cross-cluster.md` — cross-cluster hub-ordering design (dns is a hub)
- `specs/pki-and-dns.md` — combined internal-CA trust + Phase-2 TLS + DNS auto-registration design
- `specs/dns-dashboards.md` — Grafana/OpenObserve dashboards design (note its status — planned vs built)

**web_urls / core dashboards (from outputs.tf):**
<summarize the `web_urls` output — AdGuard Home UI + enabled exporters (node/adguard/unbound/
process/systemd), with exact ports>

**Notes for the doc authors:**
<anything else worth knowing — e.g. this cluster is ALREADY correctly covered in CLAUDE.md's
"## Clusters" enumeration sentence and the cross-cluster-hub paragraph, so the CLAUDE.md author
should make NO change for dns — only README.md and docs/README.md need new entries>
```

When done, print a short confirmation to stdout, then stop.
