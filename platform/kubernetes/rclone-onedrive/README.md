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

## Safety / data-loss protection (2026-06-21)

Same hardening as [`rclone-gdrive`](../rclone-gdrive/#safety--data-loss-protection-2026-06-21)
— `rclone sync` deletes local files absent from the source, so `sync-and-report.sh`:

- **Source-non-empty guard** before syncing (aborts if `onedrive:` lists empty or
  errors) — especially relevant here, since a re-auth landing on the wrong/empty
  `drive_id` would otherwise mirror as "delete everything".
- **`--max-delete 200`** tripwire (tunable via `MAX_DELETE`).
- **Real exit-code capture** through the `tee` pipe (BusyBox has no `pipefail`).
- **Fail-safe `success=0` metric** via EXIT trap for pre-sync failures.
- **`activeDeadlineSeconds: 3000`** on the CronJob to bound hung runs.
- **`--exclude "/Personal Vault/**"`** — the locked Personal Vault can't be listed
  (`ObjectHandle is Invalid`) and would fail the run; it's excluded from sync.

## Performance (`--fast-list` + `--onedrive-delta`)

OneDrive's cost is **Microsoft Graph per-request latency + 429 throttling** (the
reason for `--tpslimit 10`), not the directory walk — so `--fast-list` alone only
got it from ~7m to ~4m45s/run (it still made thousands of list calls for ~21k
items). The real lever is **`--onedrive-delta`**: it lists via Graph's flat
delta/changes feed (~1000 items/page → a handful of paginated calls), bringing a
no-change run to **~34s**. It lists the *whole* drive regardless of sync path —
fine here, since the source is the drive root (`onedrive:`) — and **requires
`--fast-list`** (both are set in `01-sync-script-configmap.yaml`). Contrast
gdrive, where `--fast-list` alone suffices (Drive's cost is the per-directory
walk, not per-request latency).

> Byte-transfer metric note: same `tail -1` (final summary line) fix as gdrive —
> see [`rclone-gdrive`](../rclone-gdrive/#performance---fast-list).

## Files
| File | What |
|---|---|
| `01-sync-script-configmap.yaml` | `rclone sync onedrive: → /backup/Graham/OneDrive/` + Pushgateway metrics |
| `02-cronjob.yaml` | Hourly at :30 (staggered from gdrive's :00) |
| `03-prometheus-rules.yaml` | Failed / stale / errors / slow alerts (`source="onedrive"`) |
| `04-secret.sops.yaml(.template)` | The `[onedrive]` rclone config (OAuth token) |

Lives in the shared `rclone` namespace (created by `rclone-gdrive`).
