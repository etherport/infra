# AWS S3 Backup System

Automated backup system for syncing NFS shares to AWS S3 with checksum verification and daily email reports.

## Overview

This system provides automated, scheduled backups of NFS shares to AWS S3 with the following features:

- **Automated Sync**: Kubernetes CronJobs run daily backups for each configured share
- **Distributed Locking**: ConfigMap-based lock mechanism prevents concurrent backups of the same share
- **Direct Verification**: Parallel S3 HEAD requests verify uploaded files exist and capture SHA256 checksums (50x cheaper than S3 Batch Operations)
- **Email Notifications**:
  - HTML-formatted failure alerts sent immediately via AWS SES
  - Daily summary reports with execution metrics for all shares
- **Exclude Patterns**: Global and per-share exclude patterns to filter unwanted files
- **Prometheus Integration**: Metrics pushed to Prometheus Pushgateway for monitoring
- **Consolidated Reports**: Single JSON report per execution with all metrics and verification results
- **Pod Security**: Runs as non-root (UID 1000) with dropped capabilities and read-only root filesystem

## Architecture

### Two-Bucket Design

This system uses a **two-bucket architecture** to separate data from operational metadata:

1. **Data Buckets** (`DEST_BUCKET`): Store actual backed-up objects
   - `archive.wind.etherport.net` - Production data with Object Lock and Glacier lifecycle policies
   - `archive-test.wind.etherport.net` - Test data bucket (no Object Lock)
   - Contains: `objects/{share}/...` - the actual backed-up files

2. **Metadata Bucket** (`METADATA_BUCKET`): Store operational artifacts
   - `logs.archive.wind.etherport.net` - Shared metadata bucket for all shares
   - Contains: Consolidated reports (`reports/{share}/{timestamp}/report.json`), temporary verification artifacts (`batch/`)
   - Does NOT have Glacier lifecycle policies (metadata needs to remain accessible)

### Data Flow

```
┌─────────────────┐
│  NFS Shares     │
│  (Sequoia NAS)  │
└────────┬────────┘
         │
         ▼
┌─────────────────┐     ┌──────────────────────────┐
│  Kubernetes     │────▶│  Data Bucket             │
│  CronJobs       │     │  archive.wind.           │
│  (per share)    │     │   etherport.net          │
│  - aws s3 sync  │     │  └─ objects/{share}/...  │
│  - parallel     │     └──────────────────────────┘
│    S3 HEAD      │
│    verification │     ┌──────────────────────────┐
│                 │────▶│  Metadata Bucket         │
└────────┬────────┘     │  logs.archive.wind.      │
         │              │   etherport.net          │
         │              │  └─ reports/{share}/...  │
         │              │  └─ batch/ (temp files)  │
         │              └──────────────────────────┘
         │
         ▼
┌─────────────────┐
│  Prometheus     │
│  Pushgateway    │
└─────────────────┘
         │
         ▼
┌─────────────────┐
│  Daily Email    │
│  Report         │
│  (HTML via SES) │
└─────────────────┘
```

## Directory Structure

```
platform/kubernetes/backups/aws-s3/
├── README.md                          # This file
├── base/                              # Base Kubernetes resources (shared by backup jobs)
│   ├── namespace.yaml                # backups namespace
│   ├── serviceaccount.yaml           # ServiceAccount with GHCR imagePullSecrets
│   ├── rbac.yaml                     # Role & RoleBinding for distributed lock (ConfigMap management)
│   ├── cronjob.yaml                  # Template CronJob for backups (per-share)
│   ├── excludes-global.txt           # Global exclude patterns (all shares)
│   └── kustomization.yaml            # Base kustomization (for shares)
├── daily-report/                      # Daily email report (single instance)
│   ├── kustomization.yaml            # Daily-report kustomization
│   ├── cronjob-email-summary.yaml    # Daily email report CronJob
│   └── email.env                     # Email configuration
├── image/                             # Docker image for backup jobs
│   ├── Dockerfile                    # AWS CLI + scripts
│   └── scripts/
│       ├── sync-and-verify.sh        # Main backup orchestration
│       ├── send-email.sh             # SES email sending
│       └── daily-report.sh           # Daily summary report generator
└── shares/                            # Per-share configurations
    ├── archive/
    ├── backups/
    ├── content/
    ├── graham/
    ├── mark/
    ├── media/
    └── scans/
        ├── kustomization.yaml         # Share-specific kustomization
        ├── patch.yaml                 # Share-specific patches (NFS path, S3 dest, etc.)
        └── excludes-share.txt         # Share-specific exclude patterns
```

## Configuration

### Shares

Each share is configured under `shares/{share-name}/` with three files:

1. **kustomization.yaml**: Defines the share's kustomization, name prefix, and ConfigMap generation
2. **patch.yaml**: Patches the base CronJob with share-specific settings
3. **excludes-share.txt**: Share-specific file exclude patterns

#### Key Settings per Share

In `patch.yaml`:

- `SHARE_NAME`: Share identifier (lowercase, no spaces)
- `DEST_BUCKET`: S3 bucket for backups (e.g., `archive.wind.etherport.net`)
- `DEST_PREFIX`: S3 key prefix (e.g., `objects/scans`)
- `nfs.server`: NFS server hostname
- `nfs.path`: NFS share path (e.g., `/var/nfs/shared/Scans`)

### Global Settings

In `base/cronjob.yaml`:

- `schedule`: Default backup schedule: `0 1 * * *` (1:00 AM PT daily)
- `timeZone`: Timezone for schedule: `America/Los_Angeles` (handles DST automatically)
- `suspend`: Set to `false` to enable automatic runs (currently enabled)
- `AWS_REGION`: AWS region (default: `us-west-2`)
- `METADATA_BUCKET`: S3 bucket for operational artifacts (default: `logs.archive.wind.etherport.net`)
- `WAIT_FOR_BATCH`: Enable direct verification after sync (default: `true`)

### Delete Protection (safety guards)

`aws s3 sync --delete` mirrors source deletions to S3. If the NFS source is
unmounted, empty, or only partially mounted (NAS reboot, share fails to mount,
stale handle), the sync would treat the missing files as deletions and **wipe
the S3 backup**. Two guards in `sync-and-verify.sh` prevent this; legitimate
small deletions still propagate normally. Defaults live in the script and are
surfaced in `base/cronjob.yaml` env for per-share override.

- **Guard 1 — source populated** (before the dry-run): aborts if `/src` is
  missing or has fewer than `DELETE_GUARD_MIN_SOURCE_ENTRIES` top-level entries
  (default `1`). This catches a downed/unmounted share — the run never reaches
  `--delete`.
- **Guard 2 — bounded deletions** (after the dry-run, before the real sync):
  the dry-run already computed exactly what would be deleted. Aborts if that
  exceeds `DELETE_GUARD_MAX_ABSOLUTE` (default `1000`, `0`=off) **or**
  `DELETE_GUARD_MAX_PERCENT` (default `10`) of the current destination object
  count. The percentage rule applies only when the destination has at least
  `DELETE_GUARD_MIN_DEST_FOR_PERCENT` objects (default `50`).
- **Guard 3 — re-assert before the destructive sync** (H3, 2026-06-23): the
  dry-run/guards above measure an *earlier* moment, and the real `--delete` is a
  separate `aws s3 sync` invocation. Immediately before it runs, Guard 1's
  source-health check runs **again**, closing the window where the NFS source
  could drop *between* the dry-run and the real sync (a stale handle / unmount
  would otherwise let `--delete` mirror a phantom mass-deletion). Relatedly, a
  failed/partial **dry-run** is now fatal (fail-closed) rather than parsing
  "0 deletions" and proceeding to an unbounded `--delete`.

When a guard trips: no sync/delete runs, S3 is untouched, and the job exits
non-zero. What happens next depends on whether the **approval flow** is
configured (it is, by default — `APPROVAL_ENABLED=true`):

- **Guard 1 (empty source)** is never approvable — an empty source is never a
  legitimate wipe — so it always hard-aborts with a failure email.
- **Guard 2 (deletion volume)** writes a pending-deletion record + full manifest
  to S3 and emails a signed **"Review & approve"** button. The email shows a
  folder rollup + sample; the link opens a confirmation page (behind Cloudflare
  Access) with the complete list and a Confirm button. See **Approval flow**
  below.

If the approval flow isn't configured (no `APPROVAL_BASE_URL` /
`APPROVAL_HMAC_SECRET`), Guard 2 falls back to a hard abort + failure email. You
can still override manually for an intended bulk deletion by re-running that
share once with the cap raised or `DELETE_GUARD_ENABLED=false`:

```bash
kubectl -n backups create job --from=cronjob/s3-sync-<share> manual-<share> --dry-run=client -o yaml \
  | yq '.spec.template.spec.containers[0].env += [{"name":"DELETE_GUARD_MAX_ABSOLUTE","value":"99999"}]' \
  | kubectl apply -f -
```

Set `DELETE_GUARD_*` per share in `shares/{share}/patch.yaml` if a share has
higher legitimate churn than the defaults allow.

### Approval flow (Cloudflare Access button)

For large but *legitimate* deletions, Guard 2 lets you approve from an email
instead of hand-editing env. Flow:

1. Guard 2 trips → the sync writes `approvals/pending/<share>/<run_id>.json`
   (rollup + sample) and `…/<run_id>.manifest.csv` (every key) to the metadata
   bucket, mints an HMAC-signed token, and emails the approve button. It still
   runs the sync **uploads-only** (no `--delete`) so new/changed files are backed
   up, then finishes **SUCCESS (subject to approval)** — `exit 0`, `success=1`,
   report `status: APPROVAL_PENDING` with a `deletionsPendingApproval` count. This
   is normal operation, **not** a failure: it does not trip `S3SyncFailed` /
   `KubeJobFailed` / the AI advisor, and the daily report shows it as
   "subject to approval" rather than an error. The held deletions wait.
2. You click **Review & approve** → `backup-approve.wind.etherport.net` (behind
   **Cloudflare Access**, restricted to the operator email). The page shows the
   full manifest + a **Download CSV** link; clicking **Confirm** (a POST, so
   email link-prefetchers can't trigger it) writes a scoped, one-time, expiring
   marker `approvals/approved/<share>.json`.
3. The **next** scheduled run for that share sees the marker, confirms the
   deletion is within the approved count, proceeds, and **consumes the marker**
   (single use). A larger deletion than approved trips the guard again.

Components: the `backup-approval` Deployment/Service (`approval-server/`, same
image, runs `approval-server.py`), the shared `approval-hmac` secret (used by
both the sync job and the server), and the `cf_tunnel_services` entry in the
Cloudflare TF (auto-creates the DNS record, tunnel ingress, and Access app +
email policy). The server can never delete anything itself — it only records
consent the next guarded run checks. Tunables: `APPROVAL_MARKER_TTL_HOURS` (48),
`APPROVAL_TOLERANCE_PERCENT` (10), `APPROVAL_TOKEN_TTL_HOURS` (72),
`APPROVAL_REQUIRE_CF_EMAIL` (off; set on + `APPROVAL_ALLOWED_EMAILS` to also
reject in-cluster hits that bypass the tunnel).

### Cross-job lock (rclone ↔ S3)

The `rclone-gdrive`/`rclone-onedrive` jobs write into the **same** NAS Backups
share this sync reads. Reading files mid-write caused checksum-verification flaps
(the "526 checksumUnavailable"). To prevent the overlap, rclone drops
`<share>/.sync-locks/rclone-<src>.lock` while transferring (removed on exit), and
`sync-and-verify.sh` `wait_for_rclone()` waits for any **fresh** lock to clear
before syncing (bounded by `RCLONE_LOCK_WAIT_SECONDS`, default 900s; locks older
than `RCLONE_LOCK_STALE_SECONDS`=3600 are treated as stale and ignored). After the
wait it proceeds regardless — the re-HEAD pass backstops any residual. Only the
`backups` share's source carries these locks (other shares see none and skip
instantly); `.sync-locks` is excluded from the sync.

### Verification status semantics

- A run is only **FAILED** on: a non-zero `aws s3 sync` exit, an actual
  checksum **mismatch** (data corruption), HEAD verification that produced no
  successful results at all, or **Guard 1** (empty/unmounted source — never
  approvable).
- A **Guard 2** trip (deletion volume awaiting approval) is **SUCCESS subject to
  approval**, NOT a failure: uploads still run, the run exits 0 with `success=1`
  and report `status: APPROVAL_PENDING` (+ `deletionsPendingApproval` count). It
  doesn't alert (`S3SyncFailed`/`KubeJobFailed`/advisor); the approval email is
  the signal. (Before 2026-06-26 it exited non-zero and read as a failed sync.)
- Objects that exist (HEAD 200) but return **no checksum metadata** —
  typically files rewritten at the source mid-run — are **not** a failure.
  They get one re-HEAD after a short settle (`CHECKSUM_RETRY_DELAY_SECONDS`,
  default 15s); any still-missing are logged as a non-fatal warning. (Before
  2026-06-21 this falsely reported FAILED — see session-log.)

### Email Notifications

In `daily-report/email.env`:

- `EMAIL_ENABLED`: Enable/disable email sending
- `EMAIL_FROM`: Sender email address (must be verified in SES)
- `EMAIL_TO`: Recipient email address
- `EMAIL_SUBJECT`: Email subject line

### Exclude Patterns

**Global excludes** (`base/excludes-global.txt`):
- Applied to ALL shares
- macOS metadata (.DS_Store, ._*, etc.)
- Common cache files (*.lrdata, Premiere previews, etc.)

**Share excludes** (`shares/{share}/excludes-share.txt`):
- Applied to specific share only
- Add patterns for share-specific exclusions

## Docker Image

Built and published automatically via GitHub Actions:

- **Trigger**: Changes to `platform/kubernetes/backups/aws-s3/image/**`
- **Registry**: GitHub Container Registry (GHCR)
- **Tags**:
  - `ghcr.io/sparked-diamond/aws-s3-sync:main` (latest)
  - `ghcr.io/sparked-diamond/aws-s3-sync:sha-{commit}` (specific version)

### Base Image

`public.ecr.aws/aws-cli/aws-cli:2.32.16` (Amazon Linux)

### Installed Tools

- `jq` - JSON parsing
- `python3` - Report generation, verification parsing
- `kubectl` - Kubernetes API access (for daily-report)
- `curl` - HTTP requests (Prometheus, S3)

## Deployment

### Prerequisites

1. **IRSA role** (`wind-irsa-s3-sync`, account `830881980142`) with the
   permissions in the IAM Policy section below. The jobs assume it via
   `AssumeRoleWithWebIdentity` using a projected SA token (no static AWS keys) —
   see [`docs/runbooks/irsa-workload-identity.md`](../../../../docs/runbooks/irsa-workload-identity.md).

2. **NFS shares** accessible from Kubernetes cluster

### IAM Policies

#### Production Policy (Normal Operations)

> **Source of truth:** the live policy is
> [`infra/terraform/aws/iam-policies/s3-backup-kubernetes-policy.json`](../../../../infra/terraform/aws/iam-policies/s3-backup-kubernetes-policy.json)
> (IAM policy `s3-backup-kubernetes-policy`, applied out-of-band via `aws iam
> create-policy-version`). The JSON below mirrors it — if they differ, trust the
> file. **Do not** re-apply an older copy of this block: the `approvals/*` grant
> is what makes the delete-approval flow work, and dropping it silently breaks
> approvals.

Use this policy for day-to-day backup operations:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "ListBucketAndLocation",
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket",
                "s3:GetBucketLocation"
            ],
            "Resource": [
                "arn:aws:s3:::archive.wind.etherport.net",
                "arn:aws:s3:::logs.archive.wind.etherport.net",
                "arn:aws:s3:::archive-test.wind.etherport.net",
                "arn:aws:s3:::infra.wind.etherport.net"
            ]
        },
        {
            "Sid": "ObjectOperations",
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject",
                "s3:DeleteObject",
                "s3:AbortMultipartUpload",
                "s3:ListBucketMultipartUploads",
                "s3:ListMultipartUploadParts",
                "s3:GetObjectTagging",
                "s3:PutObjectTagging",
                "s3:GetObjectVersion",
                "s3:DeleteObjectVersion"
            ],
            "Resource": [
                "arn:aws:s3:::archive.wind.etherport.net/objects/*",
                "arn:aws:s3:::archive.wind.etherport.net/batch/*",
                "arn:aws:s3:::logs.archive.wind.etherport.net/reports/*",
                "arn:aws:s3:::logs.archive.wind.etherport.net/batch/*",
                "arn:aws:s3:::logs.archive.wind.etherport.net/approvals/*",
                "arn:aws:s3:::archive-test.wind.etherport.net/objects/*",
                "arn:aws:s3:::archive-test.wind.etherport.net/batch/*",
                "arn:aws:s3:::infra.wind.etherport.net/*"
            ]
        }
    ]
}
```

**Note**:
- This policy restricts access to `objects/*`, `reports/*`, and `batch/*` prefixes only, preventing accidental deletion of other bucket contents
- `s3:GetObject` permission covers HEAD operations used for direct verification
- No S3 Batch Operations or IAM PassRole permissions needed (simplified from previous S3 Batch Operations approach)

#### Maintenance Policy (Bucket Cleanup)

**⚠️ TEMPORARY USE ONLY** - Use this policy when you need to clean up Object Lock protected files:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "ListBucketAndLocation",
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket",
                "s3:ListBucketVersions",
                "s3:GetBucketLocation"
            ],
            "Resource": [
                "arn:aws:s3:::archive.wind.etherport.net",
                "arn:aws:s3:::logs.archive.wind.etherport.net",
                "arn:aws:s3:::archive-test.wind.etherport.net"
            ]
        },
        {
            "Sid": "ObjectOperations",
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject",
                "s3:DeleteObject",
                "s3:AbortMultipartUpload",
                "s3:ListBucketMultipartUploads",
                "s3:ListMultipartUploadParts",
                "s3:GetObjectTagging",
                "s3:PutObjectTagging",
                "s3:GetObjectVersion",
                "s3:DeleteObjectVersion"
            ],
            "Resource": [
                "arn:aws:s3:::archive.wind.etherport.net/*",
                "arn:aws:s3:::logs.archive.wind.etherport.net/*",
                "arn:aws:s3:::archive-test.wind.etherport.net/*"
            ]
        },
        {
            "Sid": "BypassGovernanceRetention",
            "Effect": "Allow",
            "Action": "s3:BypassGovernanceRetention",
            "Resource": [
                "arn:aws:s3:::archive.wind.etherport.net/*",
                "arn:aws:s3:::logs.archive.wind.etherport.net/*",
                "arn:aws:s3:::archive-test.wind.etherport.net/*"
            ]
        }
    ]
}
```

**Key differences**:
- Allows deletion on all objects (`/*` instead of `objects/*`, `reports/*`, and `batch/*`)
- Includes `s3:BypassGovernanceRetention` permission

**⚠️ IMPORTANT**: Revert to the Production Policy immediately after maintenance is complete!

### Deploy a New Share

1. Create directory: `shares/{share-name}/`

2. Copy configuration from existing share:
   ```bash
   cp -r shares/scans/* shares/{share-name}/
   ```

3. Edit `shares/{share-name}/kustomization.yaml`:
   - Update `namePrefix: s3-sync-{share-name}-`

4. Edit `shares/{share-name}/patch.yaml`:
   - Update `SHARE_NAME` value
   - Update `DEST_PREFIX` value
   - Update `nfs.path` to correct NFS share path
   - Update `DEST_BUCKET` if using different bucket

5. Edit `shares/{share-name}/excludes-share.txt`:
   - Add share-specific exclude patterns

6. Apply via Flux or kubectl:
   ```bash
   kubectl apply -k shares/{share-name}/
   ```

### Deploy Daily Email Report

The daily email report CronJob is deployed separately (only once, not per-share):

```bash
kubectl apply -k daily-report/
```

This creates a single CronJob that monitors all shares and sends one consolidated daily email report.

### Enable/Disable Automatic Backups

**Disable** (suspend):
```bash
kubectl -n backups patch cronjob s3-sync-{share}-s3-sync-template -p '{"spec":{"suspend":true}}'
```

**Enable** (resume):
```bash
kubectl -n backups patch cronjob s3-sync-{share}-s3-sync-template -p '{"spec":{"suspend":false}}'
```

### Manual Backup Execution

```bash
kubectl -n backups create job --from=cronjob/s3-sync-{share}-s3-sync-template manual-{share}-$(date +%s)
```

Monitor:
```bash
kubectl -n backups logs -f job/manual-{share}-{timestamp}
```

## Monitoring

### Prometheus Metrics

Metrics are pushed to Prometheus Pushgateway after each backup run:

- `homelab_backup_last_run_timestamp_seconds` - Last run timestamp
- `homelab_backup_last_run_duration_seconds` - Run duration
- `homelab_backup_last_run_bytes_total` - Bytes transferred
- `homelab_backup_last_run_files_total` - Files transferred
- `homelab_backup_last_run_success` - Success flag (1=success, 0=failure)
- `homelab_backup_verification_files_succeeded` - Number of files successfully verified
- `homelab_backup_verification_files_failed` - Number of files that failed verification

**Labels**: `job=aws-s3-sync`, `share={share}`, `bucket={bucket}`

### Daily Email Reports

Sent daily at 6:00 AM PT via `s3-sync-daily-report` CronJob.

**Report Contents**:
- Summary: Total executions, completed, in-progress, errors
- Total files and bytes transferred (last 24 hours)
- Per-execution cards with:
  - Share name
  - Status (completed/in-progress/error)
  - Files and data transferred
  - Start/end times and duration

**Metrics Source**: Consolidated report JSON files from S3 (`reports/{share}/{timestamp}/report.json`)

### S3 Artifacts

Each backup run produces a **consolidated report** in the **metadata bucket** (`logs.archive.wind.etherport.net`):

```
s3://logs.archive.wind.etherport.net/
├── reports/                              # Permanent consolidated reports
│   └── {share}/{timestamp}/report.json   # Consolidated report with all metrics
└── batch/                                # Temporary verification artifacts (auto-cleaned)
```

The consolidated report contains:
- Execution metadata (ID, share, status, timestamps, duration)
- Summary statistics (files transferred, verified, succeeded, failed, bytes, transfer rate)
- Source and destination paths
- Sync details (exit code, files, bytes)
- Verification results (batch job ID, status, success/failure counts)
- Warnings and errors

Actual backed-up data is stored in the **data buckets**:
```
s3://archive.wind.etherport.net/objects/{share}/...       # Production data
s3://archive-test.wind.etherport.net/objects/{share}/...  # Test data (scans share)
```

**Timestamp Format**: `YYYYMMDDTHHMMSSZ` (e.g., `20251231T013042Z`)

## Troubleshooting

### Check CronJob Status

```bash
# List all backup CronJobs
kubectl -n backups get cronjobs

# Check specific share
kubectl -n backups describe cronjob s3-sync-{share}-s3-sync-template
```

### View Recent Job Executions

```bash
# List recent jobs for a share
kubectl -n backups get jobs | grep s3-sync-{share}

# View job logs
kubectl -n backups logs job/{job-name}
```

### Common Issues

**Issue**: No files transferred (0 files)
- **Cause**: Exclude patterns filtering all files, or no changes since last sync
- **Fix**: Review exclude patterns, check NFS mount

**Issue**: Email not received
- **Cause**: SES sender/recipient not verified, EMAIL_ENABLED=false
- **Fix**: Verify email addresses in SES, check `daily-report/email.env`

**Issue**: Verification failures reported
- **Cause**: Files failed to upload, network issues during transfer, or files deleted between sync and verification
- **Symptoms**: Consolidated report shows `verifiedFailed > 0`, email alert sent
- **Fix**: Check report.json for specific failed files, verify NFS source files still exist, re-run backup
- **Verification**: Review verification details in `s3://logs.archive.wind.etherport.net/reports/{share}/{timestamp}/report.json`

**Issue**: Job pods stuck in ImagePullBackOff
- **Cause**: Missing GHCR pull secrets
- **Fix**: Verify `ghcr-creds` secret exists in backups namespace

**Issue**: Run aborted by delete-protection guard (`[delete-guard] ABORT`)
- **Cause**: Source appeared empty/unmounted (Guard 1) or the run would have
  deleted an anomalous volume of objects (Guard 2) — usually a NAS share that
  failed to mount, or a genuine bulk deletion above the cap
- **Symptoms**: Job exits non-zero with no sync performed, `success=0` metric,
  "Delete-protection guard tripped" email; **S3 is untouched**
- **Fix**: Confirm the NFS source is mounted and populated, then re-run. For an
  intended bulk deletion, re-run that share once with `DELETE_GUARD_MAX_ABSOLUTE`
  / `DELETE_GUARD_MAX_PERCENT` raised or `DELETE_GUARD_ENABLED=false` (see
  Configuration → Delete Protection)

**Issue**: `checksumUnavailable > 0` in a report (no mismatches)
- **Cause**: Objects rewritten at the source during verification (e.g. an
  rclone import into the same NAS share) — HEAD succeeded but no checksum
  metadata yet. **Not corruption** and no longer a failure as of 2026-06-21
- **Fix**: None required; a re-HEAD pass clears most, residuals self-heal next
  run. To force checksum metadata onto stuck objects, re-upload them

### View S3 Consolidated Report

```bash
# Download consolidated report
aws s3 cp s3://logs.archive.wind.etherport.net/reports/{share}/{timestamp}/report.json - | jq .

# List recent runs for a share
aws s3 ls s3://logs.archive.wind.etherport.net/reports/{share}/ | tail -10
```

## Backup Schedule

Default schedule: **1:00 AM PT daily** (all shares)

Shares can override the schedule in their `patch.yaml`:
```yaml
spec:
  schedule: "30 8 * * *"    # 8:30 AM PT daily
  timeZone: "America/Los_Angeles"
```

Daily email report: **6:00 AM PT** (summarizes previous 24 hours)

## Security

- **AWS Credentials**: Stored as Kubernetes Secret, encrypted with SOPS
- **Direct Verification**: Parallel S3 HEAD requests verify uploaded files and capture SHA256 checksums
- **Bucket Owner Checks**: All S3 operations validate expected bucket owner
- **Read-only NFS Mounts**: Source NFS shares mounted read-only
- **RBAC**: Limited ServiceAccount permissions for ConfigMap management (distributed locking)
- **Pod Security**: Non-root execution (UID 1000), dropped capabilities, seccomp profile
- **Distributed Locking**: Prevents concurrent backups of the same share via ConfigMap mutex

## Maintenance

### Update Exclude Patterns

**Global** (affects all shares):
```bash
# Edit excludes-global.txt
vim platform/kubernetes/backups/aws-s3/base/excludes-global.txt

# Apply via Flux or commit and push
```

**Per-share**:
```bash
# Edit share-specific excludes
vim platform/kubernetes/backups/aws-s3/shares/{share}/excludes-share.txt

# Apply
kubectl apply -k shares/{share}/
```

### Update Docker Image

Changes to `image/**` trigger automatic rebuild via GitHub Actions.

To use a specific image version:
```yaml
# In base/cronjob.yaml
image: ghcr.io/sparked-diamond/aws-s3-sync:sha-{commit-hash}
```

### Rotate AWS Credentials

There is **no static AWS key to rotate** (M75 IRSA). The jobs assume the
`wind-irsa-s3-sync` role via `AssumeRoleWithWebIdentity` using a short-lived,
auto-renewing projected SA token — credentials rotate themselves on every run.
To change AWS access, edit the role/trust policy in its Terraform stack
(`infra/terraform/aws/cluster-irsa/`); see
[`docs/runbooks/irsa-workload-identity.md`](../../../../docs/runbooks/irsa-workload-identity.md).

The only secret these jobs still consume via `envFrom` is `approval-hmac`
(`APPROVAL_HMAC_SECRET`, shared with the approval server). To rotate it:

```bash
# Decrypt, edit, re-encrypt the approval-hmac secret, then apply via Flux
sops ../approval-server/01-hmac-secret.sops.yaml
```

## Best Practices

1. **Test new shares manually** before enabling automatic schedule
2. **Monitor first few runs** to ensure exclude patterns are correct
3. **Review daily email reports** for unexpected failures or data transfer volumes
4. **Keep exclude patterns updated** to avoid backing up cache/temp files
5. **Verify checksums periodically** by checking S3 Batch Operations reports
6. **Set appropriate schedules** to avoid overlapping backup windows

## Support

For issues or questions:
- Check logs: `kubectl -n backups logs job/{job-name}`
- Review S3 run summaries: `s3://logs.archive.wind.etherport.net/batch/runs/{share}/`
- Examine Prometheus metrics in Grafana
- Check daily email reports for execution history
