# UnifiBackupFailed

Fires when `unifi_backup_status > 0` for 5 minutes — the unifi-backup
CronJob script reported failure on at least one target (UDM / Protect).
Severity: warning. No auto-action.

## Symptom

PrometheusRule `unifi-backup.rules / UnifiBackupFailed` firing for a
specific `target` label. The daily 04:00 PT backup of UDM config /
UniFi Protect config to NFS/S3 failed.

## Verified root cause(s)

- UDM / Protect API credential expired or scope changed (UniFi tends
  to rotate session tokens; the backup script uses a long-lived
  credential that occasionally needs refresh).
- Network path to UDM (10.10.1.1) broken — pairs with `VPNGatewayDown`
  or a broader SDN regression.
- NFS / S3 destination unwritable (mount unhealthy, B2 endpoint down,
  credential rotated).
- The backup pod itself crashing (image issue, missing secret) —
  pairs with `PodCrashLooping`.

## Fix history

- 2026-05-22 (commit f5aa1e3): Initial M46 backup coverage. No fix
  commits since — alert hasn't fired in production.

## Verification steps

1. Most recent pod logs:
   `kubectl -n backups logs -l app=unifi-backup --tail=200`
2. Recent Job runs:
   `kubectl -n backups get jobs -l app=unifi-backup --sort-by=.metadata.creationTimestamp`
3. Test UDM reachability from the cluster:
   `kubectl -n backups run test --rm -it --image=curlimages/curl -- curl -ksv https://10.10.1.1`
4. After fix, watch the next scheduled run (04:00 PT) or trigger
   manually:
   `kubectl -n backups create job --from=cronjob/unifi-backup manual-$(date +%s)`

## Advisor action guidance

- `noop` is the most common correct outcome — root cause is usually
  credential / destination issue requiring operator action.
- `restart_pods` is not useful for a CronJob-driven workload (no
  long-lived pod).
- `pause_cronjob` (Tier 2, manual) is appropriate if a known credential
  rotation is in flight and the operator wants to suppress alerts
  during the rotation window.
- Avoid `delete_completed_jobs` here — the failed Job records are
  the diagnostic surface.
