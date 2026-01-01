# Velero - Kubernetes Backup and Restore

Velero is our Kubernetes backup solution for disaster recovery and data protection.

## Overview

- **Purpose**: Automated backup of Kubernetes resources and persistent volumes
- **Storage**: S3 bucket `velero.wind.etherport.net` (us-west-2)
- **Method**: File-system backup using Kopia
- **Backup Frequency**: Daily at 2 AM
- **Retention**: 30 days
- **Credentials**: Separate IAM user `velero-backup`

## Architecture

```
┌─────────────────┐
│   Kubernetes    │
│    Cluster      │
│                 │
│  ┌──────────┐   │     ┌──────────────┐
│  │  Velero  │───┼────▶│  S3 Bucket   │
│  │  Server  │   │     │   velero.    │
│  └──────────┘   │     │ wind.ether-  │
│       │         │     │  port.net    │
│  ┌──────────┐   │     └──────────────┘
│  │   Node   │   │
│  │  Agents  │   │
│  └──────────┘   │
│   (Kopia)       │
└─────────────────┘
```

## What Gets Backed Up

### Kubernetes Resources
- Deployments, ReplicaSets, StatefulSets
- Services, Ingresses, IngressRoutes
- ConfigMaps, Secrets
- PersistentVolumeClaims (metadata)
- Custom Resources (CRDs)

### Persistent Volume Data
- File-system level backup of PVC contents
- Uses Kopia for deduplication and compression
- Incremental backups (only changed data)

## Current Backup Schedule

| Namespace | Schedule | Method | Retention | Size |
|-----------|----------|--------|-----------|------|
| home-automation | Daily 2 AM | File-system (Kopia) | 30 days | ~523 MB |

## Installation

### Prerequisites

1. **S3 Bucket**
   - Name: `velero.wind.etherport.net`
   - Region: `us-west-2`
   - Versioning: Enabled
   - Encryption: SSE-S3

2. **IAM User**
   - User: `velero-backup`
   - Policy: See [IAM Policy](#iam-policy) below

### Helm Installation

```bash
# Add Velero Helm repository
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
helm repo update

# Create namespace
kubectl create namespace velero

# Create credentials secret
cat > /tmp/velero-credentials <<EOF
[default]
aws_access_key_id=<ACCESS_KEY>
aws_secret_access_key=<SECRET_KEY>
EOF

kubectl create secret generic cloud-credentials \
  --namespace velero \
  --from-file=cloud=/tmp/velero-credentials

rm /tmp/velero-credentials

# Install Velero
helm install velero vmware-tanzu/velero \
  --namespace velero \
  --values values.yaml
```

See [values.yaml](values.yaml) for complete Helm configuration.

### Install Velero CLI

```bash
# macOS
cd /tmp
curl -L -o velero.tar.gz https://github.com/vmware-tanzu/velero/releases/download/v1.17.1/velero-v1.17.1-darwin-amd64.tar.gz
tar -xzf velero.tar.gz
sudo mv velero-v1.17.1-darwin-amd64/velero /usr/local/bin/
rm -rf velero*

# Verify installation
velero version
```

## Usage

### List Backups

```bash
velero backup get
```

### Create Manual Backup

**Backup specific namespace:**
```bash
velero backup create ha-manual \
  --include-namespaces=home-automation \
  --default-volumes-to-fs-backup \
  --wait
```

**Backup multiple namespaces:**
```bash
velero backup create multi-ns-backup \
  --include-namespaces=home-automation,plex,monitoring \
  --default-volumes-to-fs-backup
```

**Backup entire cluster:**
```bash
velero backup create cluster-backup \
  --default-volumes-to-fs-backup
```

### View Backup Details

```bash
# Summary
velero backup describe <backup-name>

# Detailed view with all resources
velero backup describe <backup-name> --details

# View logs
velero backup logs <backup-name>
```

### Restore from Backup

**Restore entire namespace:**
```bash
velero restore create --from-backup <backup-name>
```

**Restore from latest scheduled backup:**
```bash
velero restore create ha-restore \
  --from-schedule home-assistant-daily \
  --wait
```

**Restore specific resources:**
```bash
velero restore create ha-restore-partial \
  --from-backup <backup-name> \
  --include-resources deployments,services,pvcs
```

**Restore to different namespace:**
```bash
velero restore create ha-restore-test \
  --from-backup <backup-name> \
  --namespace-mappings home-automation:home-automation-test
```

### Manage Schedules

**List schedules:**
```bash
velero schedule get
```

**Create new schedule:**
```bash
velero schedule create <name> \
  --schedule="0 2 * * *" \
  --include-namespaces=<namespace> \
  --default-volumes-to-fs-backup \
  --ttl=720h
```

**Delete schedule:**
```bash
velero schedule delete <name>
```

**Pause/unpause schedule:**
```bash
velero schedule pause <name>
velero schedule unpause <name>
```

### Delete Backups

**Delete single backup:**
```bash
velero backup delete <backup-name>
```

**Delete multiple backups:**
```bash
velero backup delete <backup-1> <backup-2> <backup-3>
```

**Delete all backups from a schedule:**
```bash
velero backup delete --selector velero.io/schedule-name=<schedule-name>
```

## Disaster Recovery Procedures

### Scenario 1: Home Assistant Pod Deleted

```bash
# Restore from latest backup
velero restore create ha-restore \
  --from-schedule home-assistant-daily \
  --wait

# Verify
kubectl get pods -n home-automation
kubectl logs -n home-automation deployment/home-assistant
```

### Scenario 2: Entire Namespace Deleted

```bash
# Delete broken namespace (if exists)
kubectl delete namespace home-automation

# Restore from backup
velero restore create ha-full-restore \
  --from-schedule home-assistant-daily \
  --wait

# Verify all resources
kubectl get all,pvc,ingress -n home-automation
```

### Scenario 3: Corrupted PVC Data

```bash
# Scale down deployment
kubectl scale deployment home-assistant -n home-automation --replicas=0

# Delete PVC
kubectl delete pvc home-assistant-config -n home-automation

# Restore (will recreate PVC with backup data)
velero restore create ha-pvc-restore \
  --from-backup <backup-name> \
  --include-resources pvc,pv \
  --wait

# Scale back up
kubectl scale deployment home-assistant -n home-automation --replicas=1
```

### Scenario 4: Cluster Rebuild

After rebuilding the Kubernetes cluster:

1. **Reinstall Velero** (same S3 bucket and credentials)
2. **Verify backup storage location:**
   ```bash
   velero backup-location get
   ```
3. **List available backups:**
   ```bash
   velero backup get
   ```
4. **Restore namespaces:**
   ```bash
   velero restore create cluster-restore \
     --from-backup <latest-cluster-backup>
   ```

## Monitoring

### Check Velero Status

```bash
# Check Velero pods
kubectl get pods -n velero

# Check backup storage location
velero backup-location get

# Check recent backup status
velero backup get

# Check for errors in logs
kubectl logs -n velero deployment/velero --tail=100
```

### Backup Verification

Velero backups show "PartiallyFailed" status due to missing VolumeSnapshot CRDs, but this is **expected and normal** when using file-system backups. To verify backup success:

```bash
# Check PodVolumeBackup status (should be "Completed")
kubectl get podvolumebackups -n velero

# Check backup size (should show bytes backed up)
velero backup describe <backup-name> | grep "Bytes Done"
```

A successful file-system backup will show:
- PodVolumeBackup status: `Completed`
- Bytes Done: matches Total Bytes
- All Kubernetes resources backed up

## Configuration Files

### values.yaml

Location: `platform/kubernetes/backups/velero/values.yaml`

Key settings:
- S3 bucket configuration
- AWS credentials reference
- Plugin configuration (AWS plugin only, CSI built-in)
- Node agent settings (Kopia)
- Kubectl image version override

### Backup Schedules

Managed via Velero CLI or can be defined as Kubernetes manifests in `schedules/` directory.

## IAM Policy

**Policy Name:** `VeleroBackupPolicy`

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:ListBucketMultipartUploads",
        "s3:AbortMultipartUpload"
      ],
      "Resource": [
        "arn:aws:s3:::velero.wind.etherport.net",
        "arn:aws:s3:::velero.wind.etherport.net/*"
      ]
    }
  ]
}
```

**Note:** EC2 permissions for EBS snapshots are not needed since we use Ceph storage with file-system backup.

## Troubleshooting

### Backup Shows "PartiallyFailed"

**This is normal** when using file-system backups without VolumeSnapshot CRDs.

Check if the actual backup succeeded:
```bash
kubectl get podvolumebackups -n velero
```

If status is `Completed` with matching bytes, the backup is successful.

### Restore Fails

Common issues:
1. **Namespace already exists**: Delete namespace first or use `--namespace-mappings`
2. **PVC already bound**: Delete PVC before restore
3. **Resource conflicts**: Use `--include-resources` or `--exclude-resources` to be selective

Check restore status:
```bash
velero restore describe <restore-name>
velero restore logs <restore-name>
```

### Backup Takes Too Long

File-system backups can take time depending on data size. Monitor progress:
```bash
kubectl get podvolumebackups -n velero -w
```

For large PVCs, consider:
- Excluding unnecessary files (logs, caches)
- Running backups during low-activity periods
- Increasing node-agent resources

### S3 Connection Issues

```bash
# Check backup storage location
velero backup-location get

# Check Velero logs
kubectl logs -n velero deployment/velero --tail=50

# Verify AWS credentials
kubectl get secret cloud-credentials -n velero -o yaml
```

## Maintenance

### Lifecycle Management

Backups are automatically deleted after TTL (30 days). To adjust:

```bash
# Update existing schedule
velero schedule create home-assistant-daily \
  --schedule="0 2 * * *" \
  --include-namespaces=home-automation \
  --default-volumes-to-fs-backup \
  --ttl=1440h  # 60 days
```

### S3 Bucket Lifecycle

Optional: Configure S3 lifecycle rules to automatically delete old backup data:

```json
{
  "Rules": [
    {
      "Id": "DeleteOldBackups",
      "Status": "Enabled",
      "Prefix": "",
      "Expiration": {
        "Days": 90
      }
    }
  ]
}
```

### Upgrade Velero

```bash
# Check current version
velero version

# Upgrade Helm chart
helm repo update
helm upgrade velero vmware-tanzu/velero \
  --namespace velero \
  --values values.yaml

# Upgrade CLI
# Download new version and replace /usr/local/bin/velero
```

## Security Considerations

### Credentials

- ✅ Separate IAM user for Velero (not shared with other services)
- ✅ Least-privilege S3 policy (bucket-specific access only)
- ✅ Kubernetes secret for AWS credentials (not hardcoded)

### Future Improvements

- [ ] Encrypt backups at rest (AWS KMS)
- [ ] Use ansible-vault for credential management
- [ ] Implement backup testing/validation automation
- [ ] Set up Velero monitoring with Prometheus/Grafana
- [ ] Configure backup notifications (success/failure alerts)

## References

- [Velero Documentation](https://velero.io/docs/)
- [Velero GitHub](https://github.com/vmware-tanzu/velero)
- [Velero Helm Chart](https://github.com/vmware-tanzu/helm-charts/tree/main/charts/velero)
- [File System Backup](https://velero.io/docs/main/file-system-backup/)
