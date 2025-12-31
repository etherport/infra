# AWS S3 Backup System

Automated backup system for syncing NFS shares to AWS S3 with checksum verification and daily email reports.

## Overview

This system provides automated, scheduled backups of NFS shares to AWS S3 with the following features:

- **Automated Sync**: Kubernetes CronJobs run daily backups for each configured share
- **Distributed Locking**: ConfigMap-based lock mechanism prevents concurrent backups of the same share
- **Checksum Verification**: S3 Batch Operations compute SHA256 checksums to verify data integrity
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
   - Contains: Manifests, batch reports, run summaries, transfer logs, verification reports
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
└────────┬────────┘     │  └─ objects/{share}/...  │
         │              └──────────────────────────┘
         │
         ├─────────────▶┌──────────────────────────┐
         │              │  Metadata Bucket         │
         │              │  logs.archive.wind.      │
         │              │   etherport.net          │
         │              │  └─ batch/manifests/...  │
         │              │  └─ batch/reports/...    │
         │              │  └─ batch/runs/...       │
         │              └────────┬─────────────────┘
         │                       │
         ▼                       ▼
┌─────────────────┐     ┌──────────────────┐
│  Prometheus     │     │  S3 Batch Ops    │
│  Pushgateway    │     │  (Checksum       │
│                 │     │   Verification)  │
└─────────────────┘     └──────────────────┘
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
├── secrets/                           # AWS credentials
│   ├── 01-aws-secret.sops.yaml       # Encrypted AWS credentials (SOPS)
│   └── 01-aws-secret.local.yaml      # Local template (not committed)
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
- `WAIT_FOR_BATCH`: Wait for S3 Batch Ops verification (default: `true`)

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

1. **AWS IAM User** (`kubernetes-s3-backup`) with appropriate permissions (see IAM Policy section below)

2. **SOPS encryption key** configured for secrets

3. **NFS shares** accessible from Kubernetes cluster

### IAM Policies

#### Production Policy (Normal Operations)

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
                "arn:aws:s3:::archive-test.wind.etherport.net"
            ]
        },
        {
            "Sid": "ObjectRWObjectsAndBatchPrefixes",
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
                "arn:aws:s3:::logs.archive.wind.etherport.net/objects/*",
                "arn:aws:s3:::logs.archive.wind.etherport.net/batch/*",
                "arn:aws:s3:::archive-test.wind.etherport.net/objects/*",
                "arn:aws:s3:::archive-test.wind.etherport.net/batch/*"
            ]
        },
        {
            "Sid": "S3BatchOperationsControlPlane",
            "Effect": "Allow",
            "Action": [
                "s3:CreateJob",
                "s3:ListJobs",
                "s3:DescribeJob",
                "s3:UpdateJobPriority",
                "s3:UpdateJobStatus"
            ],
            "Resource": "*"
        },
        {
            "Sid": "AllowPassBatchJobRole",
            "Effect": "Allow",
            "Action": "iam:PassRole",
            "Resource": "arn:aws:iam::830881980142:role/s3-batch-ops-checksum-role"
        }
    ]
}
```

**Note**: This policy restricts access to `objects/*` and `batch/*` prefixes only, preventing accidental deletion of other bucket contents.

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
            "Sid": "ObjectRWObjectsAndBatchPrefixes",
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
        },
        {
            "Sid": "S3BatchOperationsControlPlane",
            "Effect": "Allow",
            "Action": [
                "s3:CreateJob",
                "s3:ListJobs",
                "s3:DescribeJob",
                "s3:UpdateJobPriority",
                "s3:UpdateJobStatus"
            ],
            "Resource": "*"
        },
        {
            "Sid": "AllowPassBatchJobRole",
            "Effect": "Allow",
            "Action": "iam:PassRole",
            "Resource": "arn:aws:iam::830881980142:role/s3-batch-ops-checksum-role"
        }
    ]
}
```

**Key differences**:
- Allows deletion on all objects (`/*` instead of `objects/*` and `batch/*`)
- Includes `s3:BypassGovernanceRetention` permission

**⚠️ IMPORTANT**: Revert to the Production Policy immediately after maintenance is complete!

#### S3 Batch Operations Role Policy

The `s3-batch-ops-checksum-role` IAM role is assumed by S3 Batch Operations to compute checksums. This role **must** have the following policy attached:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "ReadObjectsToComputeChecksum",
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:GetObjectVersion",
                "s3:GetObjectAttributes",
                "s3:GetObjectRetention",
                "s3:GetObjectLegalHold"
            ],
            "Resource": [
                "arn:aws:s3:::archive.wind.etherport.net/objects/*",
                "arn:aws:s3:::logs.archive.wind.etherport.net/objects/*",
                "arn:aws:s3:::archive-test.wind.etherport.net/objects/*"
            ]
        },
        {
            "Sid": "WriteChecksumMetadata",
            "Effect": "Allow",
            "Action": [
                "s3:PutObjectTagging",
                "s3:PutObjectVersionTagging"
            ],
            "Resource": [
                "arn:aws:s3:::archive.wind.etherport.net/objects/*",
                "arn:aws:s3:::logs.archive.wind.etherport.net/objects/*",
                "arn:aws:s3:::archive-test.wind.etherport.net/objects/*"
            ]
        }
    ]
}
```

**Trust Relationship** for `s3-batch-ops-checksum-role`:
```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "batchoperations.s3.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
```

**⚠️ CRITICAL**: The `s3:GetObjectRetention` and `s3:GetObjectLegalHold` permissions are **required** for buckets with Object Lock enabled (like `archive.wind.etherport.net`). Without these permissions, S3 Batch Operations jobs will fail immediately with access denied errors.

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
- `homelab_backup_last_run_batch_job_created` - S3 Batch job created flag

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

**Metrics Source**: Consolidated report JSON files from S3 (`{share}/{timestamp}/report.json`)

### S3 Artifacts

Each backup run produces a **consolidated report** in the **metadata bucket** (`logs.archive.wind.etherport.net`):

```
s3://logs.archive.wind.etherport.net/
└── {share}/{timestamp}/report.json      # Consolidated report with all metrics
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

**Issue**: S3 Batch Operations job fails immediately (status: Failed after 15 seconds)
- **Cause**: Missing Object Lock permissions on `s3-batch-ops-checksum-role` IAM role
- **Symptoms**: Batch job transitions from `New` → `Failed` in ~15 seconds, no task results generated
- **Fix**: Ensure `s3-batch-ops-checksum-role` has `s3:GetObjectRetention` and `s3:GetObjectLegalHold` permissions (see S3 Batch Operations Role Policy section)
- **Verification**: Check IAM role policy attached to `s3-batch-ops-checksum-role`

**Issue**: S3 Batch Operations job fails (other causes)
- **Cause**: Bucket ownership mismatch, incorrect role ARN
- **Fix**: Verify `S3_BATCH_ROLE_ARN` matches actual role, check `EXPECTED_BUCKET_OWNER`

**Issue**: Job pods stuck in ImagePullBackOff
- **Cause**: Missing GHCR pull secrets
- **Fix**: Verify `ghcr-creds` secret exists in backups namespace

### View S3 Consolidated Report

```bash
# Download consolidated report
aws s3 cp s3://logs.archive.wind.etherport.net/{share}/{timestamp}/report.json - | jq .

# List recent runs for a share
aws s3 ls s3://logs.archive.wind.etherport.net/{share}/ | tail -10
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
- **Checksum Verification**: SHA256 FULL_OBJECT checksums via S3 Batch Operations
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

1. Update `secrets/01-aws-secret.sops.yaml`:
   ```bash
   # Decrypt, edit, re-encrypt
   sops secrets/01-aws-secret.sops.yaml
   ```

2. Apply updated secret:
   ```bash
   kubectl apply -f secrets/01-aws-secret.sops.yaml
   ```

3. Restart running pods (if any):
   ```bash
   kubectl -n backups delete pods -l app=aws-s3-sync
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
