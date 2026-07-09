# velero DR sync — Garage → S3 Deep Archive (M137 Phase 3)

Offsite DR for the local-primary velero backups. velero now writes its Kopia repo
to **Garage on the NAS** (M137 Phase 1/2), which killed the S3 maintenance egress.
This weekly job mirrors that repo to S3 for the "1" in 3-2-1:

```
Garage (NAS, primary)  ──weekly rclone sync──▶  s3://velero.wind.etherport.net/dr/  ──lifecycle @30d──▶  Glacier Deep Archive
```

- **rclone** reads Garage over its S3 API (local, free) and mirrors to S3. **Uploads
  are free ingress — this reintroduces NO egress** (unlike a velero S3 BSL, whose
  maintenance *downloaded* from S3).
- **Auth:** the `garage` remote uses the static `GK…` velero key; the `s3` remote
  uses **IRSA** (`env_auth`, role `wind-irsa-velero`, SA `velero-dr-sync`).
- **Lifecycle:** the `dr/` prefix transitions to Deep Archive after **30 days** (not
  sooner — a delay keeps short-lived churned Kopia blocks in Standard so they never
  hit Deep Archive's 180-day early-deletion penalty). See `infra/terraform/aws/s3`.
- **Alerts** (`03-alerts.yaml`): `GarageRepoDown` (primary repo down → all backups
  fail) and `VeleroDRSyncStale` (>8d → no fresh offsite copy).

**NB the `archive.wind.etherport.net` bucket is SEPARATE** — that's the NAS/iCloud
offsite archive (the `s3-sync` family), not velero. Keep them distinct.

## Piggybacking: pve-config offsite (M130) — `04-pve-config-offsite.yaml`

A **daily** CronJob (`pve-config-offsite`) that reuses this dir's machinery — same
`velero-dr-sync` SA + IRSA (`wind-irsa-velero`, already granted the velero bucket) +
rclone config — to mirror the pve config/Ceph-MON backups NAS→S3. It NFS-mounts ONLY
`/var/nfs/shared/Proxmox/Backups/pve-config` (the tiny ~3.4MB tarballs from
`pve-config-backup.yml`, NOT the giant PVE VM-backup images) → `s3://velero…/pve-config/`.
Runs as uid/gid `977:988` (the tarballs' NAS owner) with an **empty-source guard** (a
failed NFS mount can't make `rclone sync` wipe the S3 copy). The velero BSL reads only
`dr/`, so this sibling prefix is inert to velero. Alert: `PveConfigOffsiteStale` (>36h).
Not velero data — just co-located here because it reuses the exact same auth path.

## DR restore (rare)
Un-archive the `dr/` objects from Deep Archive (bulk retrieval ~12h) → `rclone copy
s3:velero.wind.etherport.net/dr/ garage:velero` (or a fresh Garage) → velero restore
from the rehydrated repo.
