# RcloneGDriveSyncFailed

Fires when `rclone_sync_success{source="gdrive",destination="nfs"} == 0`
for 5 minutes. Severity: critical. No auto-action.

## Symptom

PrometheusRule `rclone-gdrive-sync / RcloneGDriveSyncFailed` firing.
The last rclone Google Drive → NFS sync run failed. Hourly backup of
Google Drive content into the on-prem NFS share is broken.

## Verified root cause(s)

- Google OAuth refresh-token rotation / revocation — most common.
  Requires operator-side re-auth via the rclone-config secret.
- Google Drive API rate-limit / quota hit during a large initial sync.
- NFS destination unwritable (mount unhealthy / UNAS down) — pairs
  with `S3SyncFailed` since they share NFS infrastructure.
- The rclone pod OOMKilled on a large file delta.
- Network path: DNS / egress / SDN regression breaking access to
  googleapis.com.

## Fix history

- 2026-05-25 (commit 72de9bc): Wired `additional-scrape-configs` for
  the rclone metrics in the first place. Pre-fix the alert couldn't
  fire because the metrics weren't being scraped.

## Verification steps

1. Latest rclone pod logs:
   `kubectl -n rclone logs -l app=gdrive-sync --tail=200`
2. Most recent Job runs:
   `kubectl -n rclone get jobs --sort-by=.metadata.creationTimestamp | tail -5`
3. OAuth token status — if logs show 401 / `token expired`:
   secret needs re-auth via `rclone config reconnect gdrive:` on a
   local box, then SOPS-encrypt and commit. Refer to the rclone-gdrive
   namespace's own runbook if it exists.
4. After fix, trigger manual sync:
   `kubectl -n rclone create job --from=cronjob/gdrive-sync manual-$(date +%s)`

## Advisor action guidance

- `noop` is the default outcome — OAuth and Google API issues are
  fundamentally operator-driven (secret rotation).
- `restart_pods` is not useful (CronJob, no long-lived pod).
- `bump_resource_request` (Tier 2) is appropriate if logs show
  OOMKilled.
- Avoid suggesting `force_cert_renewal` or any cert action — this is
  OAuth, not TLS.
