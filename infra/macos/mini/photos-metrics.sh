#!/bin/bash
# Shared helper: push iCloud-Photos-backup run metrics to the Prometheus Pushgateway, so the
# headless mini's batch jobs are observable in Prometheus/Grafana/Alertmanager (M79).
#
# Sourced by photos-export.sh (nightly) and photos-export-resume.sh (supervised). Pushing is
# ALWAYS non-fatal — a monitoring outage must never fail or block a backup. Until the infra
# agent exposes pushgateway behind Traefik (see PUSHGATEWAY default), these pushes just
# no-op with a logged "push failed".
#
# PUSHGATEWAY is the base URL of the (Traefik-exposed) pushgateway; override via env.
PUSHGATEWAY="${PUSHGATEWAY:-http://pushgateway.wind.etherport.net}"

# push_photos_metrics <rc> <duration_s> <photos> <exported> <missing> <mode> [job]
#   job defaults to "photos_export" (the nightly). The resume wrapper passes
#   "photos_export_resume" so the two don't overwrite each other's group.
push_photos_metrics() {
  local rc="${1:-1}" dur="${2:-0}" photos="${3:-0}" exported="${4:-0}" missing="${5:-0}" \
        mode="${6:-local}" job="${7:-photos_export}" now
  now="$(date +%s)"
  # Per-run group (replaced on every push for this job/instance).
  local body="# TYPE ${job}_last_run_timestamp_seconds gauge
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
# TYPE ${job}_info gauge
${job}_info{mode=\"${mode}\"} 1
"
  if curl -fsS --max-time 10 --data-binary "${body}" \
       "${PUSHGATEWAY}/metrics/job/${job}/instance/mini" >/dev/null 2>&1; then
    echo "$(date '+%F %T') metrics: pushed ${job} (rc=${rc} photos=${photos} exported=${exported} missing=${missing})"
  else
    echo "$(date '+%F %T') metrics: push failed (non-fatal; is pushgateway exposed at ${PUSHGATEWAY}?)"
  fi
  # Last-success timestamp lives in its OWN group so a later FAILED run can't wipe it — this
  # is what the staleness alert keys on ("no success in >26h" catches both failures + skips).
  if [ "${rc}" = "0" ]; then
    curl -fsS --max-time 10 --data-binary \
      "# TYPE ${job}_last_success_timestamp_seconds gauge
${job}_last_success_timestamp_seconds ${now}
" "${PUSHGATEWAY}/metrics/job/${job}_lastsuccess/instance/mini" >/dev/null 2>&1 || true
  fi
}
