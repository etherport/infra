# VeleroBackupFailed

Fires when `increase(velero_backup_failure_total[25h]) > 0` for 5
minutes — Velero recorded at least one fully-failed backup in the
last 25h. Severity: warning. No auto-action.

## Symptom

PrometheusRule `velero-backups.rules / VeleroBackupFailed` firing on a
Velero schedule. Distinct from `VeleroBackupPartial` — this means the
backup as a whole did not complete.

## Verified root cause(s)

- BackupStorageLocation unavailable: B2 / S3 endpoint unreachable,
  expired credentials, bucket policy regression.
- Velero pod itself unhealthy mid-backup (rare; usually pairs with
  `VeleroDown`).
- DefaultVolumesToFsBackup / kopia uploader failure when restic / kopia
  can't talk to the repository.
- VolumeSnapshotLocation misconfigured (CSI driver issue).

## Fix history

- 2026-05-25 (commit f1beaf4): Switched expr from raw counter `> 0` to
  `increase([25h]) > 0` so historical failures no longer hold the
  alert firing forever. Alert auto-clears 25h after the last failure.

## Verification steps

1. Find failed backup(s):
   `velero get backups | grep -E "Failed|FailedValidation"`
2. Pull logs from the failed backup:
   `velero backup logs <name> 2>&1 | tail -100`
3. Check BackupStorageLocation health:
   `kubectl -n velero get backupstoragelocations` — Phase should be
   `Available`, not `Unavailable`.
4. Check the Velero pod itself:
   `kubectl -n velero logs deploy/velero --tail=200 | grep -iE "error|fail"`
5. After fix, trigger a fresh run to confirm green path:
   `velero backup create test-$(date +%s) --from-schedule=<name>`

## Advisor action guidance

- `trigger_velero_backup_now` is NOT useful for fresh failures — same
  root cause, same failure.
- `noop` + Loki + `velero backup logs` is the standard advisor flow.
- `restart_pods(namespace=velero, selector=app=velero)` is appropriate
  ONLY if `VeleroDown` is also firing and a fresh pod might recover —
  not for backup-data-path failures.
- BackupStorageLocation / credential rotation is NOT in the action
  set — operator job.
