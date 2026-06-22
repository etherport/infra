#!/bin/bash
# Shared helper: push iCloud-Photos-backup run metrics to the Prometheus Pushgateway, so the
# headless mini's batch jobs are observable in Prometheus/Grafana/Alertmanager (M79).
#
# Sourced by photos-export.sh (nightly) and photos-export-resume.sh (supervised). Pushing is
# ALWAYS non-fatal — a monitoring outage must never fail or block a backup.
#
# PUSHGATEWAY base URL; override via env. MUST be https:// — the Traefik web:80 entrypoint
# 301-redirects to 443, which breaks metric POSTs.
PUSHGATEWAY="${PUSHGATEWAY:-https://pushgateway.wind.etherport.net}"

# classify_missing <report.csv> — echoes "<unavailable> <resolvable>".
#   unavailable = structurally un-fetchable (edited Live-Photo motion clips, *_edited*.mov)
#   resolvable  = genuinely missing originals a DOWNLOAD_MISSING pass could fix (target: 0)
classify_missing() {
  local csv="$1"
  [ -f "$csv" ] || { echo "0 0"; return; }
  python3 - "$csv" <<'PY' 2>/dev/null || echo "0 0"
import csv,sys,re
u=r=0
for row in csv.DictReader(open(sys.argv[1])):
    if str(row.get('missing','')).strip().lower() in ('1','true','yes'):
        if re.search(r'_edited.*\.mov$', row.get('filename','').lower()): u+=1
        else: r+=1
print(u, r)
PY
}

# count_orphans <export_dir> <export_db> — echoes the number of files on disk that are NOT in
# the export ledger (i.e. untracked duplicates/orphans). A clean pipeline keeps this FLAT;
# a growing value means something produced new dups (ran without --exportdb, a race, etc.).
# Opens the DB read-only so it's safe to run alongside an export. Walks DEST (slowish over SMB).
count_orphans() {
  local dest="$1" db="$2"
  [ -d "$dest" ] && [ -f "$db" ] || { echo -1; return; }
  python3 - "$dest" "$db" <<'PY' 2>/dev/null || echo -1
import os,sqlite3,sys
dest,db=sys.argv[1],sys.argv[2]
keep=set(os.path.basename(r[0]) for r in
         sqlite3.connect(f"file:{db}?mode=ro",uri=True).execute("SELECT filepath FROM export_data"))
n=0
for root,_,files in os.walk(dest):
    for f in files:
        if f=='.DS_Store' or f.startswith('.osxphotos_export.db'): continue
        if f not in keep: n+=1
print(n)
PY
}

# push_photos_metrics <rc> <dur_s> <photos> <exported> <missing> <missing_unavail> <missing_resolv> <mode> [job]
#   job defaults to "photos_export"; the resume wrapper passes "photos_export_resume".
push_photos_metrics() {
  local rc="${1:-1}" dur="${2:-0}" photos="${3:-0}" exported="${4:-0}" missing="${5:-0}" \
        m_unavail="${6:-0}" m_resolv="${7:-0}" mode="${8:-local}" job="${9:-photos_export}" now
  now="$(date +%s)"
  # Trustworthiness guard (M79 adversarial review): a watchdog-KILLED run (rc!=0) has no clean
  # summary, so exported/missing parse to 0 — which would FALSELY read as "0 missing / nothing
  # to back up". And even a clean run (rc=0) whose --report CSV was truncated over SMB makes
  # classify_missing return "0 0", so resolvable=0 would be pushed while photos are genuinely
  # missing — AND last_success would be stamped. Both are silent-data-loss masks. So:
  #   - parsed=1 only if rc==0 AND the run actually processed photos (photos>0).
  #   - if NOT parsed: push -1 ("unknown") for the count family, never misleading 0s.
  #   - if parsed: DERIVE resolvable = missing - unavailable (authoritative summary `missing`
  #     minus the structurally-unfetchable split) so a CSV/classify under-count can't zero it.
  #   - last_success is gated on parsed (below), so a clean-but-unparsed run can't stamp success.
  local parsed=0
  if [ "${rc}" = "0" ] && [ "${photos}" -gt 0 ] 2>/dev/null; then
    parsed=1
    [ "${m_unavail}" -ge 0 ] 2>/dev/null || m_unavail=0
    m_resolv=$(( missing - m_unavail )); [ "${m_resolv}" -lt 0 ] && m_resolv=0
  else
    exported=-1; missing=-1; m_unavail=-1; m_resolv=-1
  fi
  local body="# TYPE ${job}_summary_parsed gauge
${job}_summary_parsed ${parsed}
# TYPE ${job}_last_run_timestamp_seconds gauge
${job}_last_run_timestamp_seconds ${now}
# TYPE ${job}_last_rc gauge
${job}_last_rc ${rc}
# TYPE ${job}_duration_seconds gauge
${job}_duration_seconds ${dur}
# TYPE ${job}_photos_total gauge
${job}_photos_total ${photos}
# TYPE ${job}_exported gauge
${job}_exported ${exported}
# TYPE ${job}_missing gauge
${job}_missing ${missing}
# TYPE ${job}_missing_unavailable gauge
${job}_missing_unavailable ${m_unavail}
# TYPE ${job}_missing_resolvable gauge
${job}_missing_resolvable ${m_resolv}
# TYPE ${job}_info gauge
${job}_info{mode=\"${mode}\"} 1
"
  # orphans (untracked files-on-disk) — emitted when the caller set PHOTOS_ORPHANS (>=0)
  if [ -n "${PHOTOS_ORPHANS:-}" ] && [ "${PHOTOS_ORPHANS}" -ge 0 ] 2>/dev/null; then
    body="${body}# TYPE ${job}_orphans gauge
${job}_orphans ${PHOTOS_ORPHANS}
"
  fi
  if curl -fsS --max-time 10 --data-binary "${body}" \
       "${PUSHGATEWAY}/metrics/job/${job}/instance/mini" >/dev/null 2>&1; then
    echo "$(date '+%F %T') metrics: pushed ${job} (rc=${rc} exported=${exported} missing=${missing} unavail=${m_unavail} resolvable=${m_resolv})"
  else
    echo "$(date '+%F %T') metrics: push failed (non-fatal; pushgateway at ${PUSHGATEWAY}?)"
  fi
  # last-success in its OWN group so a failed run can't wipe it (staleness alert keys on this).
  # Gated on `parsed` (not just rc==0) so a clean-but-unparsed run (truncated summary/CSV) can
  # NOT stamp success and silence the staleness alert while data is actually missing.
  if [ "${parsed}" = "1" ]; then
    curl -fsS --max-time 10 --data-binary \
      "# TYPE ${job}_last_success_timestamp_seconds gauge
${job}_last_success_timestamp_seconds ${now}
" "${PUSHGATEWAY}/metrics/job/${job}_lastsuccess/instance/mini" >/dev/null 2>&1 || true
  fi
}
