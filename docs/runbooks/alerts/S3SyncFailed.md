# S3SyncFailed

Fires when `homelab_backup_last_run_success == 0` for 5 minutes for any
`share` label. Severity: warning. No auto-action.

## Symptom

PrometheusRule `s3-sync.rules / S3SyncFailed` firing. The pushgateway
metric for the latest s3-sync run reported failure for at least one
configured NFS share. Daily-report CronJob aggregates these into the
06:00 PT email.

## Verified root cause(s)

- NFS mount failure — share unmounted / server unreachable from the
  pod's node (most common; NFS server is the same UNAS that's also
  a Velero/Kopia target).
- AWS auth failure — since M75 the s3-sync CronJob assumes
  `wind-irsa-s3-sync` via `AssumeRoleWithWebIdentity` (no static key),
  so a failure means the projected SA token / OIDC trust / IAM policy
  broke. Check the `[preflight] aws sts get-caller-identity` output in
  the pod log.
- The s3-sync container OOMKilled on a large share — pairs with
  `PodOOMKilled` on the share's job.
- ttlSecondsAfterFinished misconfig hiding the failed Job from
  enumeration but leaving the metric stuck at 0 (the 2026-05-23
  pattern; fixed by extending TTL to 25h).

## Fix history

- 2026-05-23 (commit 52a145f): Extended `ttlSecondsAfterFinished` on
  s3-sync CronJobs from 1h to 25h so the daily-report can actually
  enumerate the previous-day's runs. (Adjacent issue, not a direct
  S3SyncFailed fix, but they cluster.)
- 2026-05-22 (commit f1751dc): Initial TTL of 1h was added to drain
  the KubeJobFailed flood from these same CronJobs.

## Verification steps

1. Identify the failing share(s):
   `homelab_backup_last_run_success == 0` in Prometheus, group by share.
2. Find the most-recent failed Job (no `app` label — grep by name; jobs are
   `s3-sync-<share>-s3-sync-template-<ts>`):
   `kubectl -n backups get jobs --sort-by=.metadata.creationTimestamp | grep s3-sync | tail -10`
3. Pod logs:
   `kubectl -n backups logs job/<failed-job-name> --tail=200`
4. NFS-side: from any pod with the mount, `ls /mnt/<share>` should
   work — if not, NFS is the issue.
5. After fix, next scheduled run advances `homelab_backup_last_run_success`
   back to 1 and alert clears.

## Advisor action guidance

- `noop` is correct for NFS / S3 credential / mount issues — those
  need operator action.
- `restart_pods` is not useful (CronJob; no long-lived pod).
- `bump_resource_request` (Tier 2) is appropriate if logs show
  OOMKilled on a specific share.
- Avoid `pause_cronjob` unless the operator has actively asked for
  silence — the daily-report email already aggregates these.
