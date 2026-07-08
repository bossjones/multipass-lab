You are the "pki" research agent in a documentation fleet for the multipass-lab repo (cwd is
already the repo root). Work fully autonomously — no clarifying questions, just finish the job.
This is a READ-ONLY research job: do not edit any file except the one fact-sheet output file below.

Read, in full or in relevant part:
- `clusters/centralized_pki/README.md`
- `clusters/centralized_pki/USAGE.md`
- `clusters/centralized_pki/DEFAULT_PASSWORDS.md`
- `clusters/centralized_pki/variables.tf`
- `clusters/centralized_pki/outputs.tf`
- `specs/centralized_pki.md`
- `specs/pki-and-dns.md`
- `specs/dynamic-traefik.md`

Verify every file path you plan to cite actually exists (Read/ls it — don't guess).

Write `.team/docs-fleet/pki.factsheet.md` with this exact structure:

```markdown
# Fact sheet: centralized_pki

**One-liner:** <one sentence — this is the lab's internal CA (step-ca) + Traefik fleet edge
reverse proxy running Authelia + Vaultwarden>

**VMs:**
| VM role | Count | Sizing | Purpose |
|---|---|---|---|
<rows for `ca` and `services`, sizing from variables.tf defaults>

**Existing docs (confirmed to exist on disk):**
- `clusters/centralized_pki/README.md`
- `clusters/centralized_pki/USAGE.md`
- `clusters/centralized_pki/DEFAULT_PASSWORDS.md`
(only list ones you actually confirmed exist)

**Specs:**
- `specs/centralized_pki.md` — main design spec
- `specs/pki-and-dns.md` — combined internal-CA trust + Phase-2 TLS + DNS auto-registration design (covers multiple clusters, pki included)
- `specs/dynamic-traefik.md` — fleet-edge Traefik reverse-proxy design (pki hosts the edge)

**web_urls / core dashboards (from outputs.tf):**
<summarize the `web_urls` output — Authelia, Vaultwarden, Traefik dashboard, step-ca health, with ports>

**Notes for the doc authors:**
<anything else worth knowing — e.g. this cluster is also referenced from CLAUDE.md in later
prose (Internal-CA trust, Internal-CA TLS, Fleet-edge Traefik paragraphs) even though it's
missing from the main "## Clusters" enumeration sentence>
```

When done, print a short confirmation to stdout, then stop.
