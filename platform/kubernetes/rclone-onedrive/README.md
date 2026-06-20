# rclone-onedrive — OneDrive → NAS backup

Pulls a personal OneDrive account down to the NAS "Backups" share hourly, which
then rides the existing **NAS → S3** sync (`backups/s3-sync-backups`). Direct
mirror of [`rclone-gdrive`](../rclone-gdrive/) — same image, NFS mount, metrics,
and alert shape, just `onedrive:` → `/backup/Graham/OneDrive/`. Read-only on
OneDrive (rclone only writes the local dest). Full chain: **OneDrive → NAS → S3.**

Account: a **personal** Microsoft account (an M365 Personal/Family subscription
just adds storage — it's still OneDrive Personal, `drive_type = personal`, not
OneDrive for Business).

## Status: live (2026-06-20)
Deployed and verified — `onedrive-sync` CronJob runs hourly (at :30); the first sync
authenticated and copied files into `/backup/Graham/OneDrive/`.

### Re-auth / token rotation
rclone's OneDrive backend needs an **interactive OAuth login** (can't run headless
on the devbox), so if the token is ever revoked or you need to re-auth:
1. On a machine **with a browser**, `rclone config` → create/refresh the `onedrive`
   remote (storage `onedrive`, blank client id/secret, region Global, personal MS
   account, OneDrive Personal). See [`04-secret.sops.yaml.template`](04-secret.sops.yaml.template).
2. `cp 04-secret.sops.yaml.template 04-secret.sops.yaml`, paste the new `token =`
   line from `rclone config show onedrive`, then `sops --encrypt --in-place
   04-secret.sops.yaml` and commit (use `git commit --no-gpg-sign` if the SSH
   signing key isn't loaded). The refresh token auto-renews the access token, so
   this is only needed if the refresh token itself is invalidated.

## Files
| File | What |
|---|---|
| `01-sync-script-configmap.yaml` | `rclone sync onedrive: → /backup/Graham/OneDrive/` + Pushgateway metrics |
| `02-cronjob.yaml` | Hourly at :30 (staggered from gdrive's :00) |
| `03-prometheus-rules.yaml` | Failed / stale / errors / slow alerts (`source="onedrive"`) |
| `04-secret.sops.yaml(.template)` | The `[onedrive]` rclone config (OAuth token) |

Lives in the shared `rclone` namespace (created by `rclone-gdrive`).
