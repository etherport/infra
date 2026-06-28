# CNPGBackupStale

Fires when no successful CNPG backup has happened in >36h
(`time() - max by (cluster, namespace) (cnpg_collector_last_available_backup_timestamp) > 129600`).
Severity: warning. Auto-eligible action: `trigger_cnpg_backup_now`.

## Symptom

PrometheusRule `backup-jobs / cnpg-backup.rules / CNPGBackupStale`
firing. Typically means a daily ScheduledBackup window was missed —
not necessarily that backups are broken. Usually clears on its own
when the next scheduled run completes.

## Verified root cause(s)

- Daily 05:00 UTC ScheduledBackup didn't fire (operator pod restart
  during the window, suspended ScheduledBackup, ScheduledBackup
  resource missing entirely after a Flux reconcile bug).
- Backup was actually failing (look for sibling `CNPGBackupFailed`) —
  in which case fix that first.
- Replica pods report `cnpg_collector_last_available_backup_timestamp=0`
  because they've never witnessed a backup. The `max by (cluster, namespace)`
  aggregator in the rule guards against this (added 2026-05-24); pre-fix
  versions would fire forever on a healthy primary.

## Fix history

- 2026-05-22 (commit f5aa1e3): Rule authored as part of M46 backup
  coverage with the raw expr
  `(time() - cnpg_collector_last_available_backup_timestamp) > 129600`
  (no aggregator).
- 2026-05-24 (commit 5808fba): Wrapped the metric in
  `max by (cluster, namespace)` to mask stale-zero replicas, which
  were firing the alert forever even on a healthy primary.

## Verification steps

1. List ScheduledBackups: `kubectl -n postgres get scheduledbackups`.
   Look for any in `Suspended` state or missing entirely.
2. Most recent successful Backup per cluster:
   `kubectl -n postgres get backups --sort-by=.metadata.creationTimestamp -o wide`
3. Trigger a backup directly:
   `kubectl -n postgres cnpg backup <cluster>` and watch:
   `kubectl -n postgres get backup <name> -w`
4. After fresh backup completes, the metric advances and alert clears
   within one scrape interval (~30s).

## Advisor action guidance

- Preferred: `trigger_cnpg_backup_now(cluster=<name>)` — auto-eligible
  via `ai_remediation: auto` label on the rule. Safe (no concurrency
  issues; CNPG queues).
- If `CNPGBackupFailed` is ALSO firing for the same cluster, defer to
  that runbook — re-triggering a broken backup gives the same failure.
- `noop` with recommendation if the ScheduledBackup resource is
  missing — advisor can't author CRDs, that's an operator/Flux fix.
