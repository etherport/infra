# Postgres Barman Backup — Activation Runbook

> ✅ **ARCHIVED — activation COMPLETE.** Barman is live: continuous WAL + daily base backup
> to `s3://postgres-barman.wind.etherport.net` (IRSA, no static key). Source of truth =
> `platform/kubernetes/cnpg/01-cluster.yaml` (+ `cue-db/01-cluster.yaml`). For **restore**, see
> `docs/runbooks/disaster-recovery.md` §9 and `platform/kubernetes/cnpg/README.md`. Kept for history.

CloudNativePG ships with [Barman Cloud](https://docs.cloudnative-pg.io/documentation/current/backup_recovery/)
support: continuous WAL archiving to S3 + scheduled `pg_basebackup`-style
full backups. Together they give point-in-time recovery (PITR) at
~second granularity — much finer than Velero's daily PV snapshots, and
crash-consistent (Postgres-aware).

## Architecture

```
postgres-cluster-{1,6,7} (postgres ns, 3 instances)
  └── barman-cloud-wal-archive ──► s3://postgres-barman.wind.etherport.net/
       ▲                                  │
       │                                  ▼
       └── ScheduledBackup (daily) ──► full backup snapshots
```

- Bucket: `postgres-barman.wind.etherport.net` (separate from Velero).
- IAM user: `barman-postgres` with least-privilege policy
  (s3:Get/Put/Delete/ListBucket scoped to that bucket).
- Retention: 30d (set via CNPG `retentionPolicy`).
- Restore: via `bootstrap.recovery` in a new Cluster spec.

## Activation steps (after TF apply)

### 1. Get the IAM access key from TF output

```bash
cd infra/terraform/aws/s3
terraform output -raw postgres_barman_access_key_id
terraform output -raw postgres_barman_secret_access_key
```

### 2. Create the SOPS-encrypted secret

```bash
cat > /tmp/barman-credentials.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: barman-s3-credentials
  namespace: postgres
type: Opaque
stringData:
  ACCESS_KEY_ID: "<paste access key id>"
  SECRET_ACCESS_KEY: "<paste secret access key>"
EOF

sops -e /tmp/barman-credentials.yaml \
  > platform/kubernetes/cnpg/05-barman-credentials.sops.yaml
rm /tmp/barman-credentials.yaml
```

### 3. Enable barman in the Cluster spec

Edit `platform/kubernetes/cnpg/01-cluster.yaml`, add under `spec:`:

```yaml
backup:
  barmanObjectStore:
    destinationPath: s3://postgres-barman.wind.etherport.net
    s3Credentials:
      accessKeyId:
        name: barman-s3-credentials
        key: ACCESS_KEY_ID
      secretAccessKey:
        name: barman-s3-credentials
        key: SECRET_ACCESS_KEY
    wal:
      compression: gzip
      encryption: AES256
    data:
      compression: gzip
      encryption: AES256
  retentionPolicy: "30d"
```

### 4. Add a daily ScheduledBackup

Create `platform/kubernetes/cnpg/06-scheduled-backup.yaml`:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: postgres-cluster-daily
  namespace: postgres
spec:
  schedule: "0 5 * * *"  # 5am UTC (matches Velero ollama-daily timing)
  backupOwnerReference: self
  cluster:
    name: postgres-cluster
```

### 5. Register both in kustomization.yaml

Add to `platform/kubernetes/cnpg/kustomization.yaml`:

```yaml
resources:
  - 00-namespace.yaml
  - 03-static-pv-recovery.yaml
  - 04-pvc-pre-bind.yaml
  - 05-barman-credentials.sops.yaml
  - 01-cluster.yaml
  - 06-scheduled-backup.yaml
  - 02-credentials.sops.yaml
```

### 6. Verify after Flux reconcile

```bash
# Continuous archiving running?
kubectl get cluster -n postgres postgres-cluster -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")]}{"\n"}'

# Listed scheduled backups?
kubectl get scheduledbackup -n postgres

# Files appearing in S3?
aws s3 ls s3://postgres-barman.wind.etherport.net/ --recursive | head
```

## Restoring from barman

Replace `03-static-pv-recovery.yaml` and `04-pvc-pre-bind.yaml` workflow
with `bootstrap.recovery`:

```yaml
spec:
  bootstrap:
    recovery:
      source: postgres-cluster-prev
      recoveryTarget:
        targetTime: "2026-05-14 04:00:00.00000+00"  # any PITR moment

  externalClusters:
    - name: postgres-cluster-prev
      barmanObjectStore:
        destinationPath: s3://postgres-barman.wind.etherport.net
        s3Credentials:
          accessKeyId: { name: barman-s3-credentials, key: ACCESS_KEY_ID }
          secretAccessKey: { name: barman-s3-credentials, key: SECRET_ACCESS_KEY }
        wal:
          compression: gzip
          encryption: AES256
```

CNPG bootstraps a new cluster from the WAL stream up to `targetTime`.

## Once barman is proven (1-2 weeks)

The Velero `postgres-daily` schedule becomes redundant. Drop:
- `platform/kubernetes/backups/velero/schedules/postgres-daily.yaml`
- Reference in `platform/kubernetes/backups/velero/schedules/kustomization.yaml`

Barman provides finer-grained recovery and is Postgres-aware (crash-
consistent) vs Velero's filesystem snapshots of a running database.
