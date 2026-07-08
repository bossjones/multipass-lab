You are the "claude-md-author" agent in a documentation fleet for the multipass-lab repo (cwd is
already the repo root). Work fully autonomously — no clarifying questions, just finish the job.
You are the SOLE owner of `CLAUDE.md` for this task — no other agent will touch it, so make one
clean, complete pass.

## Read first

- All 5 fact sheets: `.team/docs-fleet/{k0s,pki,unifi,netbox,dns}.factsheet.md`
- The current `CLAUDE.md`, especially its "## Clusters" section near the top (right after
  "## Purpose").

## What to do

The "## Clusters" section currently has one paragraph enumerating clusters, e.g. (paraphrased):
"The clusters are `clusters/centralized_logging/` (...; see `specs/centralized_logging.md`),
`clusters/centralized_monitoring/` (...), `clusters/centralized_netbox/` (...; see
`specs/centralized_netbox.md`), and `clusters/centralized_dns/` (...; see
`specs/centralized_dns.md`)."

Per the fact sheets:
- `centralized_netbox` and `centralized_dns` are ALREADY correctly covered here — do not touch
  their wording.
- `centralized_k0s`, `centralized_pki`, and `centralized_unifi` are missing from this enumeration
  entirely (pki and unifi are also missing from every later paragraph in the file; k0s has zero
  mentions anywhere).

Add ONE clause each for `centralized_k0s`, `centralized_pki`, and `centralized_unifi` to this
enumeration, matching the EXACT existing prose pattern: `` `clusters/<name>/` `` (backtick path)
+ a one-clause bolded-key-tech description + `` see `specs/<name>.md` `` backtick reference,
joined into the flowing sentence with commas/`and` the same way the existing clauses are joined.
Keep the sentence grammatical — you may need to restructure the joining commas/`and` placement
since you're going from 4 items to 7, but do NOT alter the wording of the 4 existing clauses
beyond what's needed to fit new ones into the list grammatically.

Suggested one-clause descriptions (adapt to match the file's voice, don't copy verbatim):
- `centralized_k0s`: a multi-node k0sctl-formed k0s Kubernetes cluster (etcd-backed, opt-in
  etcd-quorum HA behind an HAProxy edge); see `specs/centralized_k0s.md`
- `centralized_pki`: the lab's internal CA (step-ca) + Traefik fleet-edge reverse proxy fronting
  Authelia and Vaultwarden; see `specs/centralized_pki.md`
- `centralized_unifi`: a version-exact UniFi homelab log-plane simulation (USG rsyslog forwarder →
  UCK Gen2 syslog-ng collector), log-pipeline only; see `specs/centralized_unifi.md`

Do NOT add new standalone paragraphs elsewhere in the file for these three (later paragraphs
already describe pki/unifi features in other contexts if they exist — leave those as-is). Only
edit the "## Clusters" enumeration sentence.

## When done

Print a short confirmation to stdout showing exactly what you changed (a short diff-style
summary), then stop.
