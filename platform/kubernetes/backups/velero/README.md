# Velero - Kubernetes Backup and Restore

Velero is our Kubernetes backup solution for disaster recovery and data protection.

## Overview

- **Purpose**: Automated backup of Kubernetes resources and persistent volumes
- **Storage**: S3 bucket `velero.wind.etherport.net` (us-west-2)
- **Method**: File-system backup using Kopia
- **Backup Frequency**: Daily at 2 AM
- **Retention**: 30 days (`monitoring-daily`: 7 days)
- **Kopia repo-maintenance**: `defaultRepoMaintainFrequency: 24h` (daily). ⚠️ Velero's
  built-in default is **hourly** — each maintenance run LISTs/GETs/rewrites the whole repo
  index in S3, so hourly × 11 repos drove ~$70/mo of S3 **request** cost (the May–Jun 2026
  bill spike; storage is only ~$7/mo). Set in `clusters/wind/helm-releases/velero.yaml`;
  the flag only applies to newly-created `BackupRepository` CRs, so existing CRs were
  patched live (`kubectl patch backuprepository -n velero … maintenanceFrequency=24h0m0s`)
  on 2026-07-01. See `docs/planning/session-log.md` 2026-07-01 (AWS cost investigation).
- **Credentials**: IRSA — assumes IAM role `wind-irsa-velero` via `AssumeRoleWithWebIdentity` + a projected SA token (no static-key secret). See [docs/runbooks/irsa-workload-identity.md](../../../../docs/runbooks/irsa-workload-identity.md).

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

### PVC Coverage

All namespaces with persistent data are backed up:

| Namespace | PVC | Size | Backed Up |
|-----------|-----|------|-----------|
| home-automation | home-assistant-config | 10Gi | ✅ |
| plex | plex-config | 25Gi | ✅ |
| dns | data-technitium-0, data-technitium-1 | 5Gi each | ✅ |
| postgres | postgres-cluster-1, -6, -8 (3 CNPG instances) | 10Gi each | ✅ |
| wikijs | wiki-js-data | 5Gi | ✅ |
| monitoring | grafana, prometheus, alertmanager | 5-10Gi | ✅ |
| traefik | traefik-ceph-pvc | 5Gi | ✅ |

## Current Backup Schedules

All schedules use file-system backup (Kopia) with 30-day (720h) retention, **except `monitoring-daily` which uses 7-day (168h) retention** (verified live + in `schedules/monitoring-daily.yaml`; the monitoring namespace also gets a 30-day copy via `infrastructure-daily`).

| Schedule | Namespaces | Time (UTC) | Purpose |
|----------|------------|------------|---------|
| `critical-apps-daily` | home-automation, plex | 2am | Core applications with user data |
| `postgres-daily` | postgres | 2am | CloudNativePG database (Wiki.js data) |
| `traefik-daily` | traefik | 2am | Ingress controller, ACME certs |
| `cue-daily` | cue | 3am | Cue app + its CNPG database |
| `technitium-daily` | dns | 3am | DNS server configuration |
| `plex-daily` | plex | 3am | Media server config/metadata |
| `wikijs-daily` | wikijs | 3am | Wiki.js application |
| `kube-system-daily` | kube-system | 3am | Core Kubernetes components |
| `authentik-daily` | authentik | 4am | SSO IdP blueprints/config |
| `infrastructure-daily` | cloudflare-ddns, monitoring, traefik, cert-manager, rclone, metallb-system | 4am | Infrastructure services |
| `monitoring-daily` | monitoring | 4am | Prometheus, Grafana, Alertmanager |
| `ollama-daily` | ollama | 5am | Ollama models/config |

### Schedule Files

All 12 schedules are GitOps-managed in `schedules/` and applied via a single
`kustomization.yaml` in that directory (one `<name>.yaml` per schedule).

To add a new schedule, drop a `<name>.yaml` next to the others and add
it to `schedules/kustomization.yaml` — Flux will reconcile it on the
next sync. No CLI `velero schedule create` needed.

### Schedule ordering vs the HelmRelease (M5)

The `Schedule` CRs live in the monolithic `clusters/wind` kustomization
**alongside** the velero HelmRelease that installs the `velero.io` CRDs. On a
**cold bootstrap** the Schedules can briefly fail to apply (their CRD isn't
installed until helm-controller reconciles the HR) — Flux **retries the
Kustomization every interval and self-heals** once velero is up. This is the
same CR-after-HelmRelease pattern the repo uses everywhere (e.g. the monitoring
`PrometheusRule`/`ServiceMonitor` objects), so it's **by design**, not a bug. A
restructure (Helm `values.schedules`, or a separate `dependsOn` Flux
Kustomization) was considered and **rejected**: on a healthy cluster it buys
nothing, and the kustomize↔Helm ownership cutover risks deleting live Schedules
on a critical backup path.

### Resource governance (M5)

velero server + node-agent set **resource `requests` only, no limits** (in
`clusters/wind/helm-releases/velero.yaml`):

- **Requests** promote both from `BestEffort` → `Burstable` QoS, so they aren't
  first to be evicted under node memory pressure (an evicted node-agent
  mid-backup ⇒ a `PartiallyFailed` run).
- **No limits** on purpose — Kopia fs-backup memory scales with repo size; a
  too-low limit would OOM-kill backups.
- **No namespace `ResourceQuota`** — evaluated and rejected. velero's backup /
  restore / kopia-maintenance pods are ephemeral with variable footprints, so
  *any* compute quota risks silently rejecting them (= silent backup failure,
  the worst outcome for a backup system). Requests-only is the safe governance
  step; revisit a *requests-based* quota only after profiling real backup memory.

## Installation

### Prerequisites

1. **S3 Bucket**
   - Name: `velero.wind.etherport.net`
   - Region: `us-west-2`
   - Versioning: Enabled
   - Encryption: SSE-S3

2. **IAM Role (IRSA)**
   - Role: `wind-irsa-velero` (account `830881980142`)
   - Trust: `system:serviceaccount:velero:velero-server` via web identity
   - Policy: See [IAM Policy](#iam-policy) below
   - Provisioned by the `infra/terraform/aws/cluster-irsa/` stack — see
     [docs/runbooks/irsa-workload-identity.md](../../../../docs/runbooks/irsa-workload-identity.md).

### Helm Installation

```bash
# Add Velero Helm repository
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
helm repo update

# Create namespace
kubectl create namespace velero

# NOTE: no static-key secret is created — auth is IRSA (AssumeRoleWithWebIdentity
# via role wind-irsa-velero + a projected SA token; the live HelmRelease sets
# credentials.useSecret=false). See docs/runbooks/irsa-workload-identity.md.
#
# Manual-bootstrap-only fallback (NOT used in prod): if you ever need to run
# velero against static keys (e.g. off-cluster debugging where IRSA is
# unavailable), create the secret and set credentials.useSecret=true:
#   cat > /tmp/velero-credentials <<EOF
#   [default]
#   aws_access_key_id=<ACCESS_KEY>
#   aws_secret_access_key=<SECRET_KEY>
#   EOF
#   kubectl create secret generic cloud-credentials \
#     --namespace velero --from-file=cloud=/tmp/velero-credentials
#   rm /tmp/velero-credentials

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

Schedules are **GitOps-managed** (`schedules/` → Flux). Do not mutate them with
`velero schedule create/delete/pause` — Flux reverts live changes. To add/change/
remove one, edit the `<name>.yaml` (and `schedules/kustomization.yaml`), commit,
push, and reconcile. Inspect current state read-only with:

```bash
kubectl get schedule -n velero      # (or: velero schedule get)
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

> **Pre-migration safety** — before tearing down the old cluster, take a
> final manual backup with file-system data:
> ```bash
> velero backup create pre-migration-$(date +%Y%m%d-%H%M) \
>   --include-namespaces home-automation,postgres,plex,ollama,monitoring,traefik,dns,wikijs,backups \
>   --default-volumes-to-fs-backup \
>   --wait
> # Verify backup is Completed AND has PV data:
> velero backup describe <name> | grep -E 'Phase|Errors|Warnings'
> kubectl get podvolumebackups -n velero | grep -vE 'Completed|NAME'   # should be empty
> ```
>
> Omitting `--default-volumes-to-fs-backup` produces a metadata-only
> backup that cannot recover PV contents. With the Helm values pinning
> `defaultVolumesToFsBackup: true` cluster-wide this flag is now the
> default, but old/cached client behaviour can still surprise you.

After rebuilding the Kubernetes cluster (Flux brings Velero back via
`clusters/wind/helm-releases/velero.yaml`):

1. **Verify backup storage location:**
   ```bash
   velero backup-location get   # default location must be Available
   ```
2. **List available backups:**
   ```bash
   velero backup get
   ```
3. **Restore everything (or a subset):**
   ```bash
   velero restore create cluster-restore --from-backup <name> --wait
   ```
4. **If PVCs come up empty** — the backup was metadata-only. Recovery
   path is to find the legacy RBD images on Ceph, build static-PV
   manifests pointing at them, and pre-bind PVCs. See the postgres
   manifests at `platform/kubernetes/cnpg/03-static-pv-recovery.yaml`
   + `04-pvc-pre-bind.yaml` for the canonical pattern.

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

### HelmRelease

Location: `clusters/wind/helm-releases/velero.yaml` (Flux-managed; the live
Helm values live inline here — the `values.yaml` in this dir is legacy).

Key settings:
- S3 bucket configuration
- IRSA auth (`credentials.useSecret=false`)
- Plugin configuration (AWS plugin only, CSI built-in)
- Node agent settings (Kopia)
- Kubectl image version override

### Backup Schedules

GitOps-only — defined as `Schedule` manifests in `schedules/` and reconciled by
Flux. Do **not** use `velero schedule create/delete` (Flux would revert it); edit
the YAML and commit.

## IAM Policy

This least-privilege policy is attached to the **`wind-irsa-velero`** IAM role
(IRSA — velero assumes it via `AssumeRoleWithWebIdentity`, no static user). It is
managed by the `infra/terraform/aws/cluster-irsa/` stack; see
[docs/runbooks/irsa-workload-identity.md](../../../../docs/runbooks/irsa-workload-identity.md).

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

# Verify IRSA auth (no static-key secret — see docs/runbooks/irsa-workload-identity.md).
# Confirm the projected SA token + role env are wired into the server pod:
kubectl get pod -n velero -l app.kubernetes.io/name=velero \
  -o jsonpath='{.items[0].spec.containers[0].env[?(@.name=="AWS_ROLE_ARN")].value}{"\n"}'
kubectl exec -n velero deploy/velero -c velero -- \
  cat /var/run/secrets/eks.amazonaws.com/serviceaccount/token | head -c 20

# Confirm the role actually assumes (look for AssumeRoleWithWebIdentity / 403s):
kubectl logs -n velero deployment/velero --tail=50 | grep -iE 'webidentity|assume|403|accessdenied'
```

## Maintenance

### Lifecycle Management

Backups are automatically deleted after TTL (30 days; `monitoring-daily` 7 days). To adjust, edit the
schedule's `<name>.yaml` in `schedules/` (`spec.template.ttl`, e.g. `1440h` for
60 days) and commit — Flux reconciles it. Do not use `velero schedule create`.

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

- ✅ IRSA — velero assumes the dedicated `wind-irsa-velero` role via
  `AssumeRoleWithWebIdentity`; **no static AWS keys in etcd** (no
  `cloud-credentials` secret). See [docs/runbooks/irsa-workload-identity.md](../../../../docs/runbooks/irsa-workload-identity.md).
- ✅ Least-privilege S3 policy (bucket-specific access only), attached to that role
- ✅ Short-lived creds — projected SA token (aud `sts.amazonaws.com`, 1h expiry),
  auto-rotated; nothing long-lived to leak or rotate

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
