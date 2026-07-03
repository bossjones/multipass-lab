#!/usr/bin/env bash
# Managed by OpenTofu (clusters/centralized_monitoring). STATIC (file(), not templated) — do NOT
# use $${...}; plain bash ${var} is intended. Runs once at first boot from the server cloud-init,
# after `docker compose up -d`, gated on enable_openobserve. Two jobs, both idempotent + best-effort:
#
#   1. Seed the app-OTLP streams (otlp_logs, as logs AND traces) by pushing one record each through
#      the local OTel Collector (:4318). Nothing in this lab pushes app OTLP data, and OpenObserve
#      creates streams lazily on first ingest, so without this the LogAnalysis/Correlation log panels
#      and the Infrastructure traces panels error with "Search stream not found: otlp_logs". The seed
#      uses a boot-time timestamp to stay inside OpenObserve's 5h ingest window (ZO_INGEST_ALLOWED_UPTO).
#   2. Import the OpenObserve dashboards dropped under $OO_DASH_DIR (one folder per subdir), upserting
#      by title (skips titles already present) — the on-VM equivalent of `just openobserve-dashboards`.
#
# Injected credentials come from the runcmd env (OO_ORG / OO_PASS). Everything else has a default.
set -u

OO_BASE="${OO_BASE:-http://localhost:5080}"
OO_COLLECTOR="${OO_COLLECTOR:-http://localhost:4318}"
OO_USER="${OO_USER:-admin@example.com}"
OO_PASS="${OO_PASS:-}"
OO_ORG="${OO_ORG:-default}"
OO_DASH_DIR="${OO_DASH_DIR:-/opt/stack/openobserve/dashboards}"
AUTH="${OO_USER}:${OO_PASS}"

log() { echo "[oo-provision] $*"; }

# --- 1. wait for OpenObserve ------------------------------------------------
i=0
until curl -fsS -o /dev/null "${OO_BASE}/healthz"; do
  i=$((i + 1))
  if [ "$i" -ge 60 ]; then
    log "openobserve never became healthy after 5m; giving up"
    exit 0
  fi
  sleep 5
done
log "openobserve healthy"

# --- 2. seed otlp_logs (logs + traces) so their streams exist ---------------
# Guarded on stream existence so a re-run doesn't pile up seed rows. The collector export is async;
# a couple of short retries cover the window where the collector is up but OpenObserve just became so.
stream_absent() { # $1 = type (logs|traces)
  ! curl -fsS -u "$AUTH" "${OO_BASE}/api/${OO_ORG}/streams?type=$1" 2>/dev/null \
    | grep -q '"name":"otlp_logs"'
}
seed_post() { # $1 = path, $2 = payload
  local n=0
  until curl -fsS -o /dev/null -X POST "${OO_COLLECTOR}$1" \
    -H 'Content-Type: application/json' -d "$2"; do
    n=$((n + 1))
    [ "$n" -ge 6 ] && return 1
    sleep 5
  done
}
NOW="$(date +%s)000000000"
END="$(date +%s)050000000"
if stream_absent logs; then
  if seed_post /v1/logs '{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"seed-service"}}]},"scopeLogs":[{"logRecords":[{"timeUnixNano":"'"$NOW"'","severityText":"INFO","body":{"stringValue":"otlp_logs seed record"},"attributes":[{"key":"seed","value":{"boolValue":true}}]}]}]}]}'; then
    log "seeded otlp_logs (logs)"
  else
    log "WARN: otlp_logs (logs) seed failed"
  fi
else
  log "otlp_logs (logs) stream already present; skip seed"
fi
if stream_absent traces; then
  if seed_post /v1/traces '{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"seed-service"}}]},"scopeSpans":[{"spans":[{"traceId":"5b8efff798038103d269b633813fc60c","spanId":"eee19b7ec3c1b174","name":"GET /seed","kind":2,"startTimeUnixNano":"'"$NOW"'","endTimeUnixNano":"'"$END"'","status":{"code":1},"attributes":[{"key":"http.method","value":{"stringValue":"GET"}},{"key":"http.route","value":{"stringValue":"/seed"}},{"key":"http.status_code","value":{"intValue":"200"}}]}]}]}]}'; then
    log "seeded otlp_logs (traces)"
  else
    log "WARN: otlp_logs (traces) seed failed"
  fi
else
  log "otlp_logs (traces) stream already present; skip seed"
fi

# --- 3. import dashboards (one folder per subdir; upsert by title) ----------
if [ ! -d "$OO_DASH_DIR" ]; then
  log "no dashboards dir at $OO_DASH_DIR; nothing to import"
  exit 0
fi

ensure_folder() { # $1 = folder name -> echoes folderId
  local name="$1" fid
  if [ "$name" = default ]; then echo default; return; fi
  fid="$(curl -fsS -u "$AUTH" "${OO_BASE}/api/v2/${OO_ORG}/folders/dashboards" 2>/dev/null \
    | jq -r --arg n "$name" '.list[]? | select(.name==$n) | .folderId' | head -n1)"
  if [ -z "$fid" ] || [ "$fid" = null ]; then
    fid="$(curl -fsS -u "$AUTH" -X POST "${OO_BASE}/api/v2/${OO_ORG}/folders/dashboards" \
      -H 'Content-Type: application/json' -d '{"name":"'"$name"'","description":""}' 2>/dev/null \
      | jq -r '.folderId')"
  fi
  echo "$fid"
}

imported=0 skipped=0 failed=0
for dir in "$OO_DASH_DIR"/*/; do
  [ -d "$dir" ] || continue
  folder="$(basename "$dir")"
  fid="$(ensure_folder "$folder")"
  if [ -z "$fid" ] || [ "$fid" = null ]; then
    log "WARN: could not resolve folder $folder; skipping its dashboards"
    continue
  fi
  existing="$(curl -fsS -u "$AUTH" "${OO_BASE}/api/${OO_ORG}/dashboards?folder=${fid}" 2>/dev/null \
    | jq -r '.dashboards[]? | (.title // .v1.title // empty)')"
  for f in "$dir"*.json; do
    [ -e "$f" ] || continue
    title="$(jq -r '.title // empty' "$f" 2>/dev/null)"
    if [ -z "$title" ]; then
      log "skip (no title / not a dashboard): $f"
      continue
    fi
    if printf '%s\n' "$existing" | grep -Fxq "$title"; then
      skipped=$((skipped + 1))
      continue
    fi
    if curl -fsS -o /dev/null -u "$AUTH" -X POST \
      "${OO_BASE}/api/${OO_ORG}/dashboards?folder=${fid}" \
      -H 'Content-Type: application/json' --data-binary @"$f"; then
      imported=$((imported + 1))
      log "imported: ${folder}/${title}"
    else
      failed=$((failed + 1))
      log "FAILED: ${folder}/${title} ($f)"
    fi
  done
done
log "dashboards: imported=${imported} skipped=${skipped} failed=${failed}"
exit 0
