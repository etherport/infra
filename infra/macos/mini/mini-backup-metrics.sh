#!/bin/bash
# Generic Pushgateway metrics for the mini's iCloud backup jobs (M80) — same mechanism as the
# photos pipeline (photos-metrics.sh), generalized so every category (contacts, calendars,
# messages, drive, …) reports identically. Sourced by the per-category backup scripts.
# Pushing is ALWAYS non-fatal — a monitoring outage must never fail or block a backup.
#
# PUSHGATEWAY MUST be https:// (Traefik web:80 301-redirects, which breaks POSTs).
PUSHGATEWAY="${PUSHGATEWAY:-https://pushgateway.wind.etherport.net}"

# push_backup_metrics <job> <rc> <dur_s> <items> [info_label]
#   job  e.g. contacts_backup / calendars_backup (becomes the metric prefix + Pushgateway job)
#   items = count of backed-up records (vcards / events / files)
# Emits (labels job=<job>,instance=mini): <job>_last_run_timestamp_seconds, _last_rc,
#   _duration_seconds, _items, _info{label}; plus _last_success_timestamp_seconds in its own
#   group (<job>_lastsuccess) so a failed run can't wipe it (the staleness alert keys on it).
push_backup_metrics() {
  local job="${1:?job required}" rc="${2:-1}" dur="${3:-0}" items="${4:-0}" label="${5:-default}" now
  now="$(date +%s)"
  local body="# TYPE ${job}_last_run_timestamp_seconds gauge
${job}_last_run_timestamp_seconds ${now}
# TYPE ${job}_last_rc gauge
${job}_last_rc ${rc}
# TYPE ${job}_duration_seconds gauge
${job}_duration_seconds ${dur}
# TYPE ${job}_items gauge
${job}_items ${items}
# TYPE ${job}_info gauge
${job}_info{label=\"${label}\"} 1
"
  if curl -fsS --max-time 10 --data-binary "${body}" \
       "${PUSHGATEWAY}/metrics/job/${job}/instance/mini" >/dev/null 2>&1; then
    echo "$(date '+%F %T') metrics: pushed ${job} (rc=${rc} items=${items} dur=${dur}s)"
  else
    echo "$(date '+%F %T') metrics: push failed (non-fatal; pushgateway at ${PUSHGATEWAY}?)"
  fi
  if [ "${rc}" = "0" ]; then
    curl -fsS --max-time 10 --data-binary \
      "# TYPE ${job}_last_success_timestamp_seconds gauge
${job}_last_success_timestamp_seconds ${now}
" "${PUSHGATEWAY}/metrics/job/${job}_lastsuccess/instance/mini" >/dev/null 2>&1 || true
  fi
}
