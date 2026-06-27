# Rclone Google Drive Sync

Automated hourly sync from Google Drive to NFS backup storage using rclone.

**Deployment Method**: This application is managed via **Flux GitOps**. Changes are deployed automatically from git commits.

## Overview

- **Namespace**: `rclone`
- **Schedule**: Hourly, on the hour (timeZone America/Los_Angeles)
- **Source**: Google Drive (My Drive)
- **Destination**: `sequoia.wind.etherport.net:/var/nfs/shared/Backups/Graham/Google Drive/`
- **Method**: One-way sync (Google Drive → NFS)
- **GitOps**: Managed by Flux (see [Flux Overview](../../../docs/setup/gitops/flux-overview.md))

## Safety / data-loss protection (2026-06-21)

`rclone sync` makes the destination identical to the source — it **deletes** local
files absent from the source listing. Hardening in `sync-and-report.sh` guards
against a transient empty/partial cloud listing (token blip, API hiccup, wrong
remote) wiping the NAS mirror:

- **Source-non-empty guard** — `rclone lsf <src> --max-depth 1` runs first; if it
  errors or returns nothing, the run aborts **before** any sync/delete.
- **`--max-delete 200`** — a run that would delete more than this aborts (tripwire
  for a garbled listing). Tunable via `MAX_DELETE` in the script; raise it for an
  intended bulk deletion.
- **Real exit-code capture** — BusyBox `sh` has no `pipefail`, so `rclone | tee`
  previously reported *tee's* status (≈ always 0), masking failures; the script
  now captures rclone's actual rc via a subshell.
- **Fail-safe metric** — an EXIT trap pushes `rclone_sync_success=0` if the run
  dies before the normal metrics push (config copy, OOM, source-guard abort), so
  failures surface immediately instead of only via the 25h staleness alert.
- **`activeDeadlineSeconds: 3000`** (CronJob) — a hung run is killed at 50 min so
  it can't block every future hourly tick under `concurrencyPolicy: Forbid`.

## Architecture

```
┌─────────────────────────────────────────────┐
│         Google Drive (My Drive)             │
│              (Source)                       │
└────────────────┬────────────────────────────┘
                 │
                 │ OAuth 2.0 API
                 │
        ┌────────▼────────┐
        │  CronJob (hourly)│
        │  rclone sync     │
        └────────┬────────┘
                 │
                 │ NFS Mount
                 │
┌────────────────▼────────────────────────────┐
│    NFS: Backups/Graham/Google Drive/        │
│    (sequoia.wind.etherport.net)             │
└─────────────────────────────────────────────┘
```

## Deployment

### Prerequisites

- Google Drive OAuth token configured in Secret
- NFS server with writable Backups share
- Kubernetes cluster with CronJob support

### GitOps Deployment (Recommended)

This application is managed by Flux. Changes are auto-deployed from git:

```bash
# Edit configuration (e.g., change schedule, sync settings)
vim platform/kubernetes/rclone-gdrive/02-cronjob.yaml

# Commit and push
git add platform/kubernetes/rclone-gdrive/02-cronjob.yaml
git commit -m "rclone: update sync configuration"
git push

# Force Flux to sync immediately (or wait ~10 minutes)
# (no flux CLI on the hosts — CLAUDE.md §3)
kubectl annotate -n flux-system gitrepository/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
kubectl annotate -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite

# Verify
kubectl get cronjob -n rclone
```

See [Making Changes to GitOps Apps](../../../docs/setup/gitops/making-changes.md) for detailed workflows.

### Manual Deployment (Not Recommended)

If you need to bypass GitOps (changes will be reverted by Flux):

```bash
kubectl apply -k platform/kubernetes/rclone-gdrive/

# Or deploy individual files:
kubectl apply -f 00-namespace.yaml
# Note: OAuth token must be configured in rclone-config Secret first
kubectl apply -f 02-cronjob.yaml
```

### Verify Deployment

```bash
# Check CronJob is scheduled
kubectl get cronjob -n rclone

# Check recent job runs
kubectl get jobs -n rclone

# View sync logs
kubectl logs -n rclone -l app=gdrive-sync --tail=50
```

## Configuration

### OAuth Token Setup

The OAuth token is stored in a Kubernetes Secret:

```bash
kubectl get secret rclone-config -n rclone
```

**To regenerate the OAuth token:**

1. Run `rclone authorize "drive"` locally
2. Copy the OAuth token JSON from output
3. Create new Secret:
   ```bash
   kubectl create secret generic rclone-config \
     --from-literal=rclone.conf="[gdrive]
   type = drive
   scope = drive
   token = {YOUR_TOKEN_JSON}
   team_drive = " \
     --namespace rclone \
     --dry-run=client -o yaml | kubectl apply -f -
   ```

### Sync Schedule

Default: Hourly (`0 * * * *`), timeZone America/Los_Angeles

To change the schedule, edit `02-cronjob.yaml`:

```yaml
spec:
  schedule: "0 * * * *"  # cron format
```

Apply changes:
```bash
kubectl apply -f 02-cronjob.yaml
```

### Excluded Files

The following file patterns are excluded from sync:

- `.DS_Store` (macOS metadata)
- `Thumbs.db` (Windows thumbnails)
- `desktop.ini` (Windows folder settings)

To add more exclusions, edit the `--exclude` arguments in the rclone command in
`01-sync-script-configmap.yaml`.

### Performance (`--fast-list`)

The sync uses **`--fast-list`** (in `01-sync-script-configmap.yaml`). Google Drive
charges one API call per directory page; without it, rclone walks the ~36k-object
tree one directory at a time under `--tpslimit 10`, which took **~23 min/run even
with zero changes**. `--fast-list` does a single recursive listing (buffered in
RAM — tens of MB, well under the 1Gi limit), cutting that to **~25s/run**. The
work is almost entirely Drive API listing, not NAS I/O (the local "Checks" are
metadata-only `stat()`, no `--checksum`), so this is safe for the NAS.

> The byte-transfer metric parses the **final** `Transferred:` summary line
> (`tail -1`), not the first per-`--stats` sample — an earlier `head -1` bug read
> the listing-phase sample (~0) and under-reported bytes. See the "Common Log
> Patterns" section for the line format.

## Testing

### Manual Sync (One-Time Job)

Create a manual job from the CronJob:

```bash
kubectl create job --from=cronjob/gdrive-sync gdrive-sync-manual -n rclone
```

Monitor the job:
```bash
kubectl logs -n rclone -l job-name=gdrive-sync-manual -f
```

### Dry Run (No Changes)

To test sync without making changes:

1. Edit `02-cronjob.yaml` and add `--dry-run` to command
2. Apply: `kubectl apply -f 02-cronjob.yaml`
3. Run manual job and check logs
4. Remove `--dry-run` when ready

## Monitoring

### Check Sync Status

```bash
# List recent jobs
kubectl get jobs -n rclone --sort-by=.metadata.creationTimestamp

# Check last job status
kubectl get job -n rclone -l app=gdrive-sync -o jsonpath='{.items[-1].status}'

# View last sync logs
kubectl logs -n rclone -l app=gdrive-sync --tail=100
```

### Job History

The CronJob keeps history of recent runs:
- **Successful jobs**: Last 3 runs
- **Failed jobs**: Last 3 runs

### Common Log Patterns

**Successful sync:**
```
Transferred: X.XXX KiB / X.XXX KiB, 100%, 0 B/s, ETA -
Checks: XXXX / XXXX, 100%
Transferred: X / X, 100%
```

**No changes:**
```
Transferred: 0 B / 0 B, -, 0 B/s, ETA -
Checks: XXXX / XXXX, 100%
Transferred: 0 / 0, 100%
```

## Troubleshooting

### Job Fails with "read-only file system"

The Backups share is the sync **destination** and must be mounted read-write.
Verify the NFS export on the server allows read-write for the Kubernetes node IPs:

```bash
# On NFS server (sequoia)
showmount -e localhost | grep Backups
```

### OAuth Token Expired

If sync fails with authentication errors:

1. Regenerate OAuth token locally: `rclone authorize "drive"`
2. Update Secret with new token (see OAuth Token Setup above)
3. Next CronJob run will use new token

### CronJob Not Running

Check CronJob status:
```bash
kubectl get cronjob gdrive-sync -n rclone
kubectl describe cronjob gdrive-sync -n rclone
```

Verify schedule is correct and CronJob is not suspended.

### NFS Mount Issues

Check pod events if job pods fail to start:
```bash
kubectl describe pod -n rclone -l app=gdrive-sync
```

Verify NFS server is reachable from Kubernetes nodes:
```bash
showmount -e sequoia.wind.etherport.net
```

## Maintenance

### Update Rclone Version

The image is digest-pinned and auto-bumped by Flux image automation
(`clusters/wind/image-automation/rclone.yaml`). To force a redeploy of the
current tag:

```bash
kubectl rollout restart cronjob/gdrive-sync -n rclone
```

### Backup OAuth Token

Export the Secret for backup:

```bash
kubectl get secret rclone-config -n rclone -o yaml > rclone-config-backup.yaml
```

**Note:** The token is stored in base64. Keep this file secure.

### View Sync Statistics

From last successful job:
```bash
kubectl logs -n rclone -l app=gdrive-sync --tail=5
```

Look for the final summary showing:
- Total files checked
- Files transferred
- Data transferred
- Elapsed time

## Resource Usage

Current resource allocation:

| Resource | Request | Limit |
|----------|---------|-------|
| CPU | 100m | 1 core |
| Memory | 256Mi | 1Gi |

Adjust in `02-cronjob.yaml` if needed based on sync performance and data volume.

## Security

- OAuth token stored in Kubernetes Secret (base64 encoded)
- NFS mount is not read-only (writable for sync)
- No external network access required (runs within cluster)
- Sync is one-way: Google Drive → NFS (NFS changes are overwritten)

## Related Documentation

- [Rclone Documentation](https://rclone.org/docs/)
- [Google Drive Rclone Backend](https://rclone.org/drive/)
- [Kubernetes CronJobs](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/)

---

**Created**: 2026-01-01
**Maintainer**: Graham Smith (grahamsm@gmail.com)
