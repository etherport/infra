# MinIO — velero primary backup repo (M137)

Local S3-compatible object store so **velero's Kopia backups + repo-maintenance
run against the NAS over the local network instead of AWS S3**. This kills the
S3 `DataTransfer-Out` egress that Kopia's `"rewriting contents from short packs"`
maintenance generated (forecast $75→$160, 2026-07) and uses **zero pve NVMe**
(the `ceph-rbd` pool is size=2 with <800 GiB usable — a 400 GB repo would eat
>50% of it).

## Architecture (3-2-1)

```
prod PVCs (Ceph) ──velero FSB/Kopia──▶ MinIO :9000 ──/data──▶ NAS NFS (sequoia:/var/nfs/shared/VeleroBackup, 22 TB free)
                                          └── rclone (batched, weekly) ──▶ S3 velero bucket ──▶ Glacier Deep Archive  [offsite DR]
```

- **Copy 1 (primary/fast restore):** MinIO on the NAS. Maintenance is local → free.
- **Copy 2 (offsite DR):** rclone MinIO→S3 (Phase 3), lifecycle → Deep Archive. Uploads only (free); nothing maintains S3 anymore.
- Prod data already lives on Ceph → genuine media/failure-domain separation.

## Prerequisite (operator action)

Create a **UniFi Drive share `VeleroBackup`** (~1 TB) on the UNAS. It auto-exports
as `sequoia.wind.etherport.net:/var/nfs/shared/VeleroBackup`. ⚠️ The NFS export
must be writable by the MinIO container's uid/gid 1000 — if MinIO logs
permission-denied on `/data` at first start, fix the share's NFS owner/access.

## Rollout phases

1. **Phase 1 (this dir):** MinIO Deployment + Service + SOPS'd root creds +
   bucket-init Job. **Wired into `clusters/wind` COMMENTED-OUT** until the NFS
   share exists (prevents an ImagePull/mount CrashLoop alert storm). Uncomment
   `../../platform/kubernetes/minio` in `clusters/wind/kustomization.yaml` to activate.
2. **Phase 2:** repoint velero's default BSL → MinIO (fresh Kopia repo); keep the
   old `aws`/S3 BSL as a **read-only** secondary through its 30-day retention so
   existing restore points survive.
3. **Phase 3:** rclone MinIO→S3 DR CronJob + S3 Deep-Archive lifecycle; retire the
   old S3 repo once retention lapses. Add a MinIO-down alert.

## Creds / access

Root creds in `01-credentials.sops.yaml` (they ARE MinIO's S3 access/secret key).
S3 endpoint in-cluster: `http://minio.minio.svc.cluster.local:9000`. Bucket: `velero`.

See also: [[velero-kopia-maintenance-s3-cost]] memory, `clusters/wind/helm-releases/velero.yaml`.
