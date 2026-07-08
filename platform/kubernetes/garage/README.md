# Garage — velero primary backup repo (M137)

Single-node [Garage](https://garagehq.deuxfleurs.fr) S3 server so **velero's Kopia
backups + repo-maintenance run against the NAS over the LAN instead of AWS S3** —
killing the S3 `DataTransfer-Out` egress that Kopia's `"rewriting contents from
short packs"` maintenance generated (forecast $75→$160, 2026-07). S3 becomes
offsite DR only.

## Why Garage, not MinIO

MinIO's erasure backend **rejects NFS** ("`no online disks found … insufficient
drives online`" — it needs `O_DIRECT`/atomic ops the UniFi Drive share can't
provide). Garage supports **split storage**, which is the whole trick here:

| Store | Backend | Why |
|---|---|---|
| `metadata_dir` (LMDB index + inlined <3 KB objects) | **Ceph-RBD PVC, 10 Gi** (~20 Gi raw, 2.5% of pool headroom) | LMDB needs mmap/atomic → block, not NFS |
| `data_dir` (content-addressed data blocks) | **NAS over NFS** (`sequoia:/var/nfs/shared/VeleroBackup`, 22 TB free) | blocks are immutable/write-once → NFS-safe; this is the bulk (~300 GB) |

So bulk backup data lives on the NAS (goal), pve NVMe cost is trivial, and it
sidesteps the NFS-metadata problem. Verified 2026-07-08: 10 MB S3 PUT → data block
on the NAS at ~90 MB/s, metadata on RBD.

## Runtime notes

- Runs as **uid/gid 988** to match the UniFi Drive share owner (NFS writes; the
  share is `drwxrwx--- 988:988`). `fsGroup: 988` also chowns the fresh RBD volume.
- **Bootstrap is an idempotent `postStart` hook** (in-pod local RPC → node ID
  auto-discovered): assigns the layout, imports velero's key, creates+grants the
  `velero` bucket. No-op once the RBD metadata is populated; re-runs cleanly on a
  fresh metadata volume (DR). Manual equivalent: `kubectl -n garage exec deploy/garage
  -- /garage -c /etc/garage.toml {status,layout,bucket,key} …`.
- **Single replica by design** (backup target, not HA). If down → backups fail
  (alerted) + restores fall back to the S3 DR copy.

## Access

- S3 endpoint (in-cluster): `http://garage.garage.svc.cluster.local:3900`, region `garage`, bucket `velero`.
- velero/rclone creds: `garage-velero-creds` secret (`AWS_ACCESS_KEY_ID` = the `GK…` key). Server config (rpc_secret/admin_token): `garage-config`.

## Rollout

1. **Phase 1 (done):** Garage running + bootstrapped, split-storage validated.
2. **Phase 2:** repoint velero's default BSL → Garage (fresh Kopia repo); keep the
   old `aws`/S3 BSL **read-only** through its 30-day retention so restore points survive.
3. **Phase 3:** rclone Garage→S3 weekly DR + S3 Deep-Archive lifecycle + a Garage-down alert.

See [[velero-kopia-maintenance-s3-cost]] and `clusters/wind/helm-releases/velero.yaml`.
