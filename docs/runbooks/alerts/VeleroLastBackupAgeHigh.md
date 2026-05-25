# VeleroLastBackupAgeHigh

Fires when `time() - velero_backup_last_successful_timestamp > 36h` for any
Velero schedule. Severity: warning. Auto-eligible action:
`trigger_velero_backup_now`.

## Symptom

PrometheusRule `velero-backups.rules / VeleroLastBackupAgeHigh` firing for
hours or days. Often shows a multi-day "since" value even though the daily
backups appear to be running on schedule.

## Root cause (verified)

Velero exposes the timestamp metric with TWO label sets:

- A **per-schedule** series: `velero_backup_last_successful_timestamp{schedule="<name>"}`
- A **global / label-less** series with `schedule=""` that does NOT advance
  as individual schedules complete — it can sit stuck at the oldest value
  forever, keeping the alert firing.

The alert was originally written without a label filter, so it picked up
the stuck global series and stayed firing.

## Fix history

- **2026-05-25 (commit f1beaf4 / earlier)** — Added `{schedule!=""}` filter
  to the alert expression in `platform/kubernetes/monitoring/06-backup-alerts.yaml`.
  Per-schedule series advances correctly; alert now reflects reality.
- **2026-05-24 (commit 5808fba)** — Removed `icloudpd` namespace from
  `infrastructure-daily` schedule (it didn't exist in this cluster, so
  Velero marked every run PartiallyFailed and the `_last_successful_`
  timestamp never advanced for that schedule).

## Verification steps

1. Query the per-schedule metric in Prometheus:
   `velero_backup_last_successful_timestamp{schedule!=""}` — every
   schedule should show a timestamp from within the last 36h.
2. If one schedule is stale, check its most recent Backup objects:
   `kubectl -n velero get backup -l velero.io/schedule-name=<schedule>`.
   Look for `PartiallyFailed` — that means a sub-resource failed (commonly
   a missing namespace or a PV without CSI snapshotter wired).
3. If the alert is just lagging behind a known-good fresh run, trigger
   one immediately via the auto-remediation action
   `trigger_velero_backup_now(schedule_name=<name>)` — safe, Velero
   handles concurrency.

## Related

- `docs/runbooks/disaster-recovery.md` — full Velero restore drill
- `platform/kubernetes/backups/velero/schedules/` — schedule manifests
