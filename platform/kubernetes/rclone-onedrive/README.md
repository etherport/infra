# rclone-onedrive — OneDrive → NAS backup

Pulls a personal OneDrive account down to the NAS "Backups" share nightly, which
then rides the existing **NAS → S3** sync (`backups/s3-sync-backups`). Direct
mirror of [`rclone-gdrive`](../rclone-gdrive/) — same image, NFS mount, metrics,
and alert shape, just `onedrive:` → `/backup/Graham/OneDrive/`. Read-only on
OneDrive (rclone only writes the local dest). Full chain: **OneDrive → NAS → S3.**

Account: a **personal** Microsoft account (an M365 Personal/Family subscription
just adds storage — it's still OneDrive Personal, `drive_type = personal`, not
OneDrive for Business).

## Status: staged, awaiting the OAuth token
This component is built but **not yet registered** in
`clusters/wind/kustomization.yaml`, because rclone's OneDrive backend needs an
**interactive OAuth login** that can't run headless on the devbox.

### Activation steps
1. On a machine **with a browser**, run `rclone config` and create a remote named
   `onedrive` (storage `onedrive`, blank client id/secret, region Global, log into
   the personal MS account, choose OneDrive Personal). See
   [`04-secret.sops.yaml.template`](04-secret.sops.yaml.template) for the click-path.
2. `rclone config show onedrive` and hand the `[onedrive]` block over.
3. I create `04-secret.sops.yaml` (`sops --encrypt`), uncomment it in
   `kustomization.yaml`, and register this dir in `clusters/wind/kustomization.yaml`.
4. Flux deploys it; a manual run verifies the first sync (the initial full pull
   may be large/slow — OneDrive throttles, hence `--tpslimit 10`).

## Files
| File | What |
|---|---|
| `01-sync-script-configmap.yaml` | `rclone sync onedrive: → /backup/Graham/OneDrive/` + Pushgateway metrics |
| `02-cronjob.yaml` | Daily 23:00 PT (before the 00:00 gdrive + 01:00 NAS→S3) |
| `03-prometheus-rules.yaml` | Failed / stale / errors / slow alerts (`source="onedrive"`) |
| `04-secret.sops.yaml(.template)` | The `[onedrive]` rclone config (OAuth token) |

Lives in the shared `rclone` namespace (created by `rclone-gdrive`).
