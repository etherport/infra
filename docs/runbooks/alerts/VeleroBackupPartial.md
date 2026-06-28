# VeleroBackupPartial

Fires when `increase(velero_backup_partial_failure_total[25h]) > 0` for
5 minutes — Velero recorded at least one PartiallyFailed backup in the
last 25h. Severity: warning. No auto-action.

## Symptom

PrometheusRule `velero-backups.rules / VeleroBackupPartial` firing on a
Velero schedule. PartiallyFailed means some resources / sub-backup
items couldn't be backed up but the backup as a whole completed.

## Verified root cause(s)

- A namespace listed in the schedule's `includedNamespaces` doesn't
  exist (e.g., the 2026-05-24 `icloudpd` case — namespace was removed
  but the schedule still referenced it).
- A PV/PVC without a wired CSI snapshotter (e.g., older
  hostPath/NFS PVs that pre-date Velero's snapshot support).
- A pod hook (pre/post-backup exec) failed — pod restart, app
  unhealthy, or hook script bug.
- M44-style collateral: a cilium / system DaemonSet rolling restart
  during the backup window, momentarily making system pods
  unrecoverable from the API server's perspective.

## Fix history

- 2026-05-25 (commit f1beaf4): Switched expr from raw counter `> 0` to
  `increase([25h]) > 0` — the underlying `velero_backup_partial_failure_total`
  is a monotonic counter that never decrements, so the pre-fix rule
  fired forever after any historical partial. With the window, alert
  auto-clears 25h after the last partial.
- 2026-05-24 (commit 5808fba): Removed missing `icloudpd` namespace
  from `infrastructure-daily` schedule — root cause of the partial.

## Verification steps

1. Find the partial backup(s):
   `velero get backups | grep PartiallyFailed`
   or `kubectl -n velero get backups --sort-by=.metadata.creationTimestamp`
2. Diagnose:
   `velero describe backup <name> --details` — lists per-resource
   errors near the bottom.
3. For schedule-referencing-missing-namespace, fix the schedule:
   `kubectl -n velero edit schedule <name>` — remove the bad namespace
   from `spec.template.includedNamespaces`. Then trigger a fresh run.
4. After 25h with no new partials, alert auto-clears.

## Advisor action guidance

- `trigger_velero_backup_now(schedule_name=<name>)` is appropriate only
  after the operator has confirmed the root cause is fixed in source
  — otherwise the new run will be partial again.
- `noop` is the most common correct outcome: the advisor should
  surface `velero describe backup` output in its email, not act.
- Schedule edits are NOT in the advisor's action set — operator job.
