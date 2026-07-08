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

## DR restore (rare)
Un-archive the `dr/` objects from Deep Archive (bulk retrieval ~12h) → `rclone copy
s3:velero.wind.etherport.net/dr/ garage:velero` (or a fresh Garage) → velero restore
from the rehydrated repo.
