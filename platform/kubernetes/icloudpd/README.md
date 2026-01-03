# iCloudPD - iCloud Photos Sync

Automated daily sync of iCloud Photos to local NFS backup storage using [icloudpd](https://github.com/icloud-photos-downloader/icloud-photos-downloader).

## Overview

This CronJob runs daily at midnight (Pacific time) to download the most recent photos from iCloud Photos to a local backup directory. It uses cookie-based authentication to avoid having to re-authenticate frequently.

### Key Features

- **Automated daily sync** at midnight Pacific time
- **Cookie-based authentication** (no password in manifests)
- **Recent photos only** (configurable, default: last 10 days)
- **Organized folder structure** by date (`YYYY/YYYY-MM-DD/`)
- **Prometheus metrics** for monitoring sync success/failure
- **NFS storage** to Backups share on Sequoia

## Architecture

```
┌──────────────────┐
│   CronJob        │  ← Runs daily at midnight
│  (icloud-sync)   │
└────────┬─────────┘
         │
         ↓
┌──────────────────┐
│  icloudpd        │  ← Downloads photos from iCloud
│  container       │
└────────┬─────────┘
         │
         ↓
┌──────────────────┐
│   NFS Mount      │  ← sequoia:/var/nfs/shared/Backups/Graham/iCloud
│  (/backup/iCloud)│
└──────────────────┘
```

## Configuration

### Schedule

Runs daily at midnight Pacific time:

```yaml
schedule: "0 0 * * *"
timeZone: "America/Los_Angeles"
```

To change the schedule, edit `02-cronjob.yaml` and commit via git (see [Making Changes](#making-changes) below).

### Sync Settings

Default sync behavior (in `01-sync-script-configmap.yaml`):

- **Recent photos**: Last 10 days (`--recent 10`)
- **Apple ID**: `graham.m.smith@mac.com`
- **Folder structure**: `{:%Y/%Y-%m-%d}` (e.g., `2025/2025-01-03/`)
- **Download path**: `/backup/iCloud/` (NFS mount)

### Cookie Authentication

iCloudPD uses cookie-based authentication to avoid frequent re-authentication:

1. Initial authentication was done manually (outside the cluster)
2. Cookies are stored in a Kubernetes Secret: `icloud-cookies`
3. CronJob mounts the secret and uses it for authentication
4. Cookies are periodically refreshed by icloudpd

## Deployment

### Prerequisites

1. **iCloud Cookies Secret**: Must be created manually (contains authentication cookies)
2. **NFS mount**: Sequoia server must be accessible at `sequoia.wind.etherport.net`
3. **Backup directory**: `/var/nfs/shared/Backups/Graham/iCloud` must exist on NFS server

### GitOps Deployment

This application is managed by Flux GitOps. Changes are deployed by committing to git:

```bash
# Edit configuration
vim platform/kubernetes/icloudpd/01-sync-script-configmap.yaml

# Commit and push
git add platform/kubernetes/icloudpd/01-sync-script-configmap.yaml
git commit -m "icloudpd: update sync settings"
git push

# Force Flux to sync immediately (or wait ~10 minutes)
flux reconcile source git flux-system
flux reconcile kustomization flux-system
```

See [Flux GitOps Overview](../../docs/gitops/flux-overview.md) for more details.

### Manual Deployment (Not Recommended)

If you need to deploy manually (bypassing GitOps):

```bash
# Deploy all resources
kubectl apply -k platform/kubernetes/icloudpd/

# Note: You must create the icloud-cookies secret separately
kubectl create secret generic icloud-cookies \
  --from-file=cookie.txt=/path/to/cookie.txt \
  -n icloudpd
```

## Making Changes

### Change Sync Schedule

```bash
# Edit the schedule
vim platform/kubernetes/icloudpd/02-cronjob.yaml

# Change schedule (cron format)
schedule: "0 2 * * *"  # Run at 2 AM instead of midnight

# Commit and push
git add 02-cronjob.yaml
git commit -m "icloudpd: change sync time to 2 AM"
git push

# Force Flux reconciliation
flux reconcile kustomization flux-system

# Verify
kubectl get cronjob -n icloudpd
```

### Change Sync Settings

```bash
# Edit the sync script
vim platform/kubernetes/icloudpd/01-sync-script-configmap.yaml

# Modify settings, e.g., download last 30 days instead of 10:
--recent 30 \

# Commit and push
git add 01-sync-script-configmap.yaml
git commit -m "icloudpd: increase sync window to 30 days"
git push

# Force Flux reconciliation
flux reconcile kustomization flux-system
```

### Update Cookie Secret

Cookies need periodic refresh (every few months). To update:

```bash
# Get new cookies using icloudpd authentication helper (outside cluster)
# Then update the secret:

kubectl delete secret icloud-cookies -n icloudpd
kubectl create secret generic icloud-cookies \
  --from-file=cookie.txt=/path/to/new-cookie.txt \
  -n icloudpd
```

## Testing

### Manual Test Run

To test changes immediately instead of waiting for the scheduled run:

```bash
# Create a test job from the CronJob
kubectl create job --from=cronjob/icloud-photos-sync icloud-test-$(date +%s) -n icloudpd

# Watch the job
kubectl get jobs -n icloudpd -w

# Check logs
kubectl logs -n icloudpd -l app=icloud-photos-sync --tail=100 -f
```

### Verify NFS Mount

```bash
# Exec into a test pod
kubectl run -it --rm debug --image=busybox -n icloudpd -- sh

# Inside the pod:
ls -la /backup/iCloud/
df -h /backup
```

## Monitoring

### Check Last Run Status

```bash
# View CronJob status
kubectl get cronjob -n icloudpd

# View recent jobs
kubectl get jobs -n icloudpd --sort-by=.metadata.creationTimestamp

# Check logs from last run
kubectl logs -n icloudpd -l app=icloud-photos-sync --tail=200
```

### Prometheus Metrics

Prometheus rules monitor sync success/failure (see `03-prometheus-rules.yaml`):

- **iCloudPhotos SyncFailed**: Alerts if sync fails
- **iCloudPhotos SyncStale**: Alerts if no successful sync in >25 hours

View metrics in Grafana or query Prometheus:

```promql
# Check sync status
icloud_sync_success{app="icloud-photos-sync"}

# View last sync time
icloud_last_sync_time{app="icloud-photos-sync"}
```

### Email Alerts

Alerts are sent via AlertManager to configured email addresses when:
- Sync fails (critical severity)
- No successful sync in >25 hours (warning severity)

## Troubleshooting

### Sync Failing

**Symptom**: Job completes but no new photos are downloaded.

**Check**:
1. View job logs:
   ```bash
   kubectl logs -n icloudpd -l app=icloud-photos-sync --tail=200
   ```

2. Common issues:
   - **Cookie expired**: Update cookies (see [Update Cookie Secret](#update-cookie-secret))
   - **NFS mount issues**: Check NFS server connectivity
   - **Permissions**: Ensure write access to `/var/nfs/shared/Backups/Graham/iCloud`
   - **Two-factor authentication**: May need to re-authenticate

### Job Not Running

**Check CronJob status**:
```bash
kubectl get cronjob -n icloudpd
kubectl describe cronjob icloud-photos-sync -n icloudpd
```

**Check if CronJob is suspended**:
```bash
# If suspended, resume it
kubectl patch cronjob icloud-photos-sync -n icloudpd -p '{"spec":{"suspend":false}}'
```

### NFS Mount Issues

**Symptom**: Job fails with "cannot access /backup" errors.

**Check**:
```bash
# Verify NFS server is reachable
ping sequoia.wind.etherport.net

# Check NFS exports on sequoia
ssh sequoia.wind.etherport.net
showmount -e localhost

# Verify path exists
ssh sequoia.wind.etherport.net ls -la /var/nfs/shared/Backups/Graham/
```

### Cookie Authentication Issues

**Symptom**: "authentication required" or "2FA required" errors.

**Solution**:
1. Run icloudpd authentication helper locally to generate new cookies
2. Update the `icloud-cookies` secret with the new cookies
3. Test with a manual job

### Out of Disk Space

**Symptom**: Job fails with "no space left on device".

**Check disk usage**:
```bash
ssh sequoia.wind.etherport.net df -h /var/nfs/shared/Backups/
```

**Solutions**:
- Clean up old photos/backups
- Reduce `--recent` days to download fewer photos
- Expand NFS volume

## Files

| File | Purpose |
|------|---------|
| `00-namespace.yaml` | Creates icloudpd namespace |
| `01-sync-script-configmap.yaml` | Sync script with icloudpd configuration |
| `02-cronjob.yaml` | CronJob that runs the sync daily |
| `03-prometheus-rules.yaml` | Monitoring alerts for sync failures |
| `04-icloud-cookies-secret.yaml` | Cookie authentication (NOT in git, .gitignore) |
| `kustomization.yaml` | Kustomize configuration for GitOps |

## Security Notes

- **Cookies Secret**: Never commit `04-icloud-cookies-secret.yaml` to git (excluded by `.gitignore`)
- **Secrets Management**: Cookies secret must be created manually or via SOPS encryption
- **NFS Security**: Consider implementing NFS access controls to limit which nodes can mount
- **Cookie Rotation**: Periodically refresh cookies (every 3-6 months recommended)

## Resources

- [icloudpd GitHub](https://github.com/icloud-photos-downloader/icloud-photos-downloader)
- [icloudpd Documentation](https://icloud-photos-downloader.github.io/icloud_photos_downloader/)
- [Flux GitOps Overview](../../docs/gitops/flux-overview.md)
- [Making Changes to GitOps Apps](../../docs/gitops/making-changes.md)

## Related Applications

- **Rclone GDrive**: Syncs Google Drive to NFS (complementary backup)
- **AWS S3 Backups**: Archives NFS shares to S3 (including iCloud photo backups)
- **Velero**: Kubernetes cluster backups
