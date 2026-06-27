# S3 Backup Validation Guide

This guide explains how to validate the integrity of existing S3 backups by comparing source file checksums with S3's stored ChecksumSHA256 metadata.

## Overview

The validation script (`validate-existing-backups.sh`) performs retroactive integrity validation by:

1. **Listing all objects in S3** with their metadata
2. **Computing SHA256 checksums** of corresponding source files (if they still exist)
3. **Retrieving S3's ChecksumSHA256** metadata (stored during upload)
4. **Comparing checksums** to detect:
   - ✅ **Valid**: Source and S3 checksums match
   - ❌ **Checksum mismatch**: Data corruption detected (CRITICAL)
   - ⚠️ **Size mismatch**: File sizes don't match
   - ⚠️ **Source missing**: Source file deleted/moved since backup
   - ⚠️ **S3 checksum missing**: Object uploaded without `--checksum-algorithm SHA256`

5. **Generating a detailed JSON report** with per-file results and summary statistics

## When to Run Validation

### Required Validation
- **After enabling source checksum computation** (one-time retroactive validation)
- **After suspected data corruption** (hardware failure, network issues, etc.)
- **Before migrating to Deep Archive** (verify integrity before lifecycle transitions)

### Recommended Validation
- **Quarterly or annually** (proactive integrity monitoring)
- **After major infrastructure changes** (NAS replacement, network upgrades, etc.)
- **Random sampling** (monthly 1-5% sample for ongoing assurance)

### Cost Considerations
- **API Costs**: ~$0.40 per million HEAD requests (for 100K objects = $0.04)
- **Compute**: Local SHA256 computation (free)
- **Storage**: Validation reports are tiny (~100KB for 10K objects)
- **Data Transfer**: None (HEAD requests don't retrieve object data)

**For 110K objects across all shares:**
- Full validation: ~$0.05 in API costs
- 10% sample: ~$0.005 in API costs

## Usage

### Option 1: Run as Kubernetes Job (Recommended)

This is the easiest way to run validation. It uses the same container image and environment as your sync jobs.

#### Validate a Single Share (Full)

```bash
# Create a validation job from template
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: s3-validation-graham-$(date +%Y%m%d%H%M%S)
  namespace: backups
spec:
  ttlSecondsAfterFinished: 86400
  backoffLimit: 0
  template:
    spec:
      serviceAccountName: s3-sync
      restartPolicy: Never
      containers:
        - name: validate
          image: ghcr.io/sparked-diamond/aws-s3-sync:main
          command: ["/bin/bash", "-lc"]
          args:
            - |
              set -euo pipefail
              acct="\$(aws sts get-caller-identity --query Account --output text)"
              [[ "\${acct}" == "830881980142" ]] || exit 2
              /scripts/validate-existing-backups.sh graham 100
          env:
            - name: SHARE_NAME
              value: "graham"
            - name: SRC_PATH
              value: "/src"
            - name: DEST_BUCKET
              value: "archive.wind.etherport.net"
            - name: DEST_PREFIX
              value: "objects/graham"
            - name: METADATA_BUCKET
              value: "logs.archive.wind.etherport.net"
            - name: AWS_REGION
              value: "us-west-2"
            - name: AWS_ACCOUNT_ID
              value: "830881980142"
            - name: PARALLEL_WORKERS
              value: "50"
            # M75 IRSA — short-lived creds via web identity (replaces the
            # aws-backup-credentials static key). aws CLI v2 uses the default chain.
            - name: AWS_ROLE_ARN
              value: "arn:aws:iam::830881980142:role/wind-irsa-s3-sync"
            - name: AWS_WEB_IDENTITY_TOKEN_FILE
              value: "/var/run/secrets/eks.amazonaws.com/serviceaccount/token"
            # aws CLI v2 web-identity cache needs a writable \$HOME (pod HOME=/).
            - name: HOME
              value: "/tmp"
          volumeMounts:
            - name: nfs-src
              mountPath: /src
              readOnly: true
            - name: aws-iam-token
              mountPath: /var/run/secrets/eks.amazonaws.com/serviceaccount
              readOnly: true
          resources:
            requests: {memory: "512Mi", cpu: "200m"}
            limits: {memory: "4Gi", cpu: "2000m"}
      volumes:
        # M75 IRSA: projected SA token (aud sts.amazonaws.com) for web identity.
        - name: aws-iam-token
          projected:
            sources:
              - serviceAccountToken:
                  audience: sts.amazonaws.com
                  expirationSeconds: 3600
                  path: token
        - name: nfs-src
          nfs:
            server: sequoia.wind.etherport.net
            path: /var/nfs/shared/Graham
EOF

# Monitor progress
kubectl logs -n backups -f job/s3-validation-graham-TIMESTAMP
```

#### Validate with Sampling (10% Random Sample)

```bash
# Just change the args to include sample percentage
# ... (same as above but change args line:)
              /scripts/validate-existing-backups.sh graham 10
```

#### Validate All Shares

```bash
# Run validation for each share in parallel
for SHARE in graham archive backups mark media content scans; do
  SHARE_UPPER="$(echo $SHARE | sed 's/\b\(.\)/\u\1/')"  # Capitalize first letter
  NFS_PATH="/var/nfs/shared/${SHARE_UPPER}"

  # Adjust for specific shares
  case $SHARE in
    graham) NFS_PATH="/var/nfs/shared/Graham" ;;
    archive) NFS_PATH="/var/nfs/shared/Archive" ;;
    backups) NFS_PATH="/var/nfs/shared/Backups" ;;
    mark) NFS_PATH="/var/nfs/shared/Mark" ;;
    media) NFS_PATH="/var/nfs/shared/Media" ;;
    content) NFS_PATH="/var/nfs/shared/Content" ;;
    scans) NFS_PATH="/var/nfs/shared/Scans" ;;
  esac

  cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: s3-validation-${SHARE}-$(date +%Y%m%d%H%M%S)
  namespace: backups
spec:
  ttlSecondsAfterFinished: 86400
  backoffLimit: 0
  template:
    spec:
      serviceAccountName: s3-sync
      restartPolicy: Never
      containers:
        - name: validate
          image: ghcr.io/sparked-diamond/aws-s3-sync:main
          command: ["/bin/bash", "-lc"]
          args:
            - |
              set -euo pipefail
              acct="\$(aws sts get-caller-identity --query Account --output text)"
              [[ "\${acct}" == "830881980142" ]] || exit 2
              /scripts/validate-existing-backups.sh ${SHARE} 100
          env:
            - name: SHARE_NAME
              value: "${SHARE}"
            - name: SRC_PATH
              value: "/src"
            - name: DEST_BUCKET
              value: "archive.wind.etherport.net"
            - name: DEST_PREFIX
              value: "objects/${SHARE}"
            - name: METADATA_BUCKET
              value: "logs.archive.wind.etherport.net"
            - name: AWS_REGION
              value: "us-west-2"
            - name: AWS_ACCOUNT_ID
              value: "830881980142"
            - name: PARALLEL_WORKERS
              value: "50"
            # M75 IRSA — short-lived creds via web identity (replaces the
            # aws-backup-credentials static key). aws CLI v2 uses the default chain.
            - name: AWS_ROLE_ARN
              value: "arn:aws:iam::830881980142:role/wind-irsa-s3-sync"
            - name: AWS_WEB_IDENTITY_TOKEN_FILE
              value: "/var/run/secrets/eks.amazonaws.com/serviceaccount/token"
            # aws CLI v2 web-identity cache needs a writable \$HOME (pod HOME=/).
            - name: HOME
              value: "/tmp"
          volumeMounts:
            - name: nfs-src
              mountPath: /src
              readOnly: true
            - name: aws-iam-token
              mountPath: /var/run/secrets/eks.amazonaws.com/serviceaccount
              readOnly: true
          resources:
            requests: {memory: "512Mi", cpu: "200m"}
            limits: {memory: "4Gi", cpu: "2000m"}
      volumes:
        # M75 IRSA: projected SA token (aud sts.amazonaws.com) for web identity.
        - name: aws-iam-token
          projected:
            sources:
              - serviceAccountToken:
                  audience: sts.amazonaws.com
                  expirationSeconds: 3600
                  path: token
        - name: nfs-src
          nfs:
            server: sequoia.wind.etherport.net
            path: ${NFS_PATH}
EOF

  echo "Started validation for ${SHARE}"
  sleep 2  # Stagger job creation
done

# Monitor all validation jobs
kubectl get jobs -n backups -l 'job-name=~s3-validation-.*' -w
```

### Option 2: Run Locally (Advanced)

If you want to run validation from your local machine or a specific server.

> **Note:** As of M75 IRSA the in-cluster Jobs no longer use static AWS keys (the
> `aws-backup-credentials` secret was removed). The static `AWS_ACCESS_KEY_ID`/
> `AWS_SECRET_ACCESS_KEY` below are **ad-hoc debug only** — for a quick local run with
> credentials you already hold. The supported path is the Kubernetes Job (Option 1).

```bash
# Set environment variables
export SHARE_NAME="graham"
export SRC_PATH="/mnt/nfs/Graham"
export DEST_BUCKET="archive.wind.etherport.net"
export DEST_PREFIX="objects/graham"
export METADATA_BUCKET="logs.archive.wind.etherport.net"
export AWS_REGION="us-west-2"
export AWS_ACCESS_KEY_ID="your-key"      # ad-hoc debug only
export AWS_SECRET_ACCESS_KEY="your-secret"  # ad-hoc debug only

# Run validation (100% of files)
./validate-existing-backups.sh graham 100

# Or run with 10% sample
./validate-existing-backups.sh graham 10
```

## Understanding Validation Reports

Validation reports are uploaded to:
```
s3://logs.archive.wind.etherport.net/validation-reports/{share}/{timestamp}/validation-report.json
```

### Report Structure

```json
{
  "validationId": "20260101T200000Z",
  "share": "graham",
  "status": "SUCCESS",  // or "CRITICAL", "FAILED", "PARTIAL"
  "startTime": "2026-01-01T20:00:00Z",
  "endTime": "2026-01-01T20:15:30Z",
  "durationSeconds": 930,
  "summary": {
    "totalObjectsInS3": 51950,
    "totalValidated": 51950,
    "samplePercent": 100,
    "valid": 51945,                    // ✅ Checksums match
    "checksumMismatch": 0,              // ❌ CRITICAL - corruption!
    "sizeMismatch": 0,                  // ⚠️ File size changed
    "sourceMissing": 5,                 // ⚠️ Source deleted
    "s3ChecksumMissing": 0              // ⚠️ Old upload without checksum
  },
  "validation": {
    "algorithm": "SHA256",
    "method": "source_vs_s3_metadata",
    "parallelWorkers": 50
  },
  "files": [
    {
      "s3_key": "objects/graham/Pictures/IMG_1234.JPG",
      "local_path": "/src/Pictures/IMG_1234.JPG",
      "status": "valid",
      "source_sha256": "abc123...",
      "s3_sha256": "abc123...",
      "size": 2457600
    },
    {
      "s3_key": "objects/graham/OldFile.txt",
      "local_path": "/src/OldFile.txt",
      "status": "source_missing",
      "error": "Source file no longer exists"
    }
  ],
  "errors": []
}
```

### Status Meanings

| Status | Meaning | Action Required |
|--------|---------|-----------------|
| **SUCCESS** | All validated files match | None - backup integrity confirmed |
| **PARTIAL** | Some files have non-critical issues | Review report, acceptable if sources were deleted |
| **FAILED** | Size mismatches or other errors | Investigate - possible sync issues |
| **CRITICAL** | Checksum mismatches detected | **URGENT** - Data corruption! Re-upload affected files |

### Downloading Reports

```bash
# List all validation reports for a share
aws s3 ls s3://logs.archive.wind.etherport.net/validation-reports/graham/ --recursive

# Download and view latest report
LATEST=$(aws s3 ls s3://logs.archive.wind.etherport.net/validation-reports/graham/ --recursive | sort | tail -1 | awk '{print $4}')
aws s3 cp s3://logs.archive.wind.etherport.net/$LATEST - | jq .

# View summary only
aws s3 cp s3://logs.archive.wind.etherport.net/$LATEST - | jq '{status, summary, errors}'

# List files with checksum mismatches (if any)
aws s3 cp s3://logs.archive.wind.etherport.net/$LATEST - | jq '.files[] | select(.status == "checksum_mismatch")'
```

## Performance

### Expected Validation Times

Based on 50 parallel workers and typical HEAD request latency (~100ms):

| Objects | Duration | API Cost |
|---------|----------|----------|
| 1,000 | ~2 minutes | $0.0004 |
| 10,000 | ~20 minutes | $0.004 |
| 50,000 | ~1.7 hours | $0.02 |
| 100,000 | ~3.3 hours | $0.04 |

**Note**: Actual time depends on:
- Source file system performance (NFS read speed for SHA256 computation)
- S3 API response times
- Number of parallel workers
- Network latency

### Optimizing Performance

**Increase parallel workers** (requires more CPU/memory):
```bash
export PARALLEL_WORKERS=100  # Default is 50
```

**Use sampling for large shares**:
```bash
# Validate random 10% sample
./validate-existing-backups.sh media 10

# Progressively increase sample if issues found
./validate-existing-backups.sh media 25
./validate-existing-backups.sh media 50
```

## Handling Validation Results

### All Files Valid (status: "valid")
✅ **No action needed.** Your backups have perfect integrity!

### Source Files Missing (status: "source_missing")
⚠️ **Expected behavior** if you deleted/moved source files after backup.

**To verify these are legitimate deletions:**
```bash
# Check when file was last in source
aws s3api head-object --bucket archive.wind.etherport.net --key objects/graham/path/to/file.jpg --query LastModified

# Compare to when you deleted the source
# If S3 backup is older than deletion, this is expected
```

### Size Mismatches (status: "size_mismatch")
⚠️ **Investigate.** Source file may have been modified after backup.

**Actions:**
1. Check if source file was intentionally modified
2. If yes, next sync will update S3 backup
3. If no, this could indicate source file corruption - restore from S3 backup

### S3 Checksum Missing (status: "s3_checksum_missing")
⚠️ **Old backups without SHA256 metadata.** Object was uploaded before `--checksum-algorithm SHA256` was enabled.

**To add checksums retroactively:**
1. Enable source checksum computation (already done in latest version)
2. Next sync will detect no changes and skip re-upload
3. Or manually re-upload: `aws s3 cp /path/to/file s3://bucket/key --checksum-algorithm SHA256`

### Checksum Mismatches (status: "checksum_mismatch")
❌ **CRITICAL - Data corruption!** Source and S3 checksums don't match.

**Immediate actions:**
1. **DO NOT DELETE S3 OBJECT** - it may be the only valid copy
2. **Verify source file integrity**:
   ```bash
   # Check file system errors
   dmesg | grep -i error
   # Run file system check
   fsck /dev/sdX  # (unmount first!)
   ```

3. **Determine which copy is correct**:
   - Check S3 upload timestamp: Was source modified after upload?
   - Check S3 Object Lock: Object protected from modification?
   - Try opening/using both versions to see which is valid

4. **Re-upload from trusted source**:
   ```bash
   aws s3 cp /path/to/valid/file s3://bucket/key --checksum-algorithm SHA256
   ```

5. **Investigate root cause**:
   - Hardware failure (RAM, disk, network)
   - Cosmic bit flip (extremely rare)
   - Software bug
   - Malicious modification

## Integration with Sync Reports

Future sync reports will include `checksumValidation` section automatically:

```json
{
  "checksumValidation": {
    "enabled": true,
    "algorithm": "SHA256",
    "totalValidated": 125,
    "matches": 125,
    "mismatches": 0,
    "unavailable": 0,
    "mismatchedFiles": []
  }
}
```

This provides **ongoing continuous validation** without needing separate validation jobs.

## Recommended Validation Schedule

### Initial Validation (One-Time)
```bash
# After deploying source checksum computation
# Validate all shares at 100% to establish baseline
for share in graham archive backups mark media content scans; do
  kubectl create job validate-${share}-initial --from=cronjob/s3-sync-${share}-s3-sync-template
done
```

### Ongoing Validation (Automated)
- **Daily**: Automatic via sync jobs (new files only)
- **Monthly**: Random 5% sample across all shares
- **Quarterly**: Full 100% validation of critical shares (graham, backups)
- **Annually**: Full 100% validation of all shares

### After Events
- After NAS replacement or migration
- After suspected power failure
- After network infrastructure changes
- Before transitioning to Deep Archive (Glacier)

## Troubleshooting

### Validation Job Fails to Start

```bash
# Check job status
kubectl describe job -n backups s3-validation-graham-TIMESTAMP

# Common issues:
# 1. Service account missing
kubectl get sa -n backups s3-sync

# 2. IRSA auth (M75) — the preflight runs `aws sts get-caller-identity`; it should
#    assume wind-irsa-s3-sync (no static aws-backup-credentials secret anymore).
#    Verify the assumed identity from a running/just-finished pod:
kubectl logs -n backups job/s3-validation-graham-TIMESTAMP | grep -i 'caller-identity\|AWS Account'
#    Or check directly: the assumed-role ARN should contain "wind-irsa-s3-sync".
kubectl exec -n backups job/s3-validation-graham-TIMESTAMP -- aws sts get-caller-identity --query Arn --output text

# 3. NFS mount issues
kubectl logs -n backups job/s3-validation-graham-TIMESTAMP
```

### Validation Runs Slowly

```bash
# Increase parallel workers
# Edit job env: PARALLEL_WORKERS=100

# Or reduce sample size
# Change args: /scripts/validate-existing-backups.sh graham 10
```

### Out of Memory

```bash
# Increase memory limits in job spec
resources:
  limits:
    memory: "8Gi"  # Increase from 4Gi
```

### Missing Dependencies

The validation script requires:
- `jq` - JSON processing
- `sha256sum` - Checksum computation
- `parallel` or `xargs` - Parallel execution
- `aws` CLI - S3 API access

These are all included in the `ghcr.io/sparked-diamond/aws-s3-sync:main` container image.

## FAQ

**Q: Does validation download objects from S3?**
A: No, only HEAD requests are made to retrieve metadata (size, checksum). No data transfer costs.

**Q: Will validation modify my backups?**
A: No, validation is read-only. It computes source checksums and compares to S3 metadata.

**Q: Can I validate Deep Archive objects?**
A: Yes! HEAD requests work on Deep Archive without restoration. Tags and metadata are always accessible.

**Q: What if source files are gone?**
A: Status will be `source_missing`. This is expected for deleted files. Report shows which files can't be validated.

**Q: How do I validate backups from before source checksums were enabled?**
A: Objects uploaded with `--checksum-algorithm SHA256` have S3 checksums. This script validates those. Objects without checksums will show `s3_checksum_missing` status.

**Q: Can I validate a specific file or directory?**
A: Currently, validation is at the share level. For specific files, modify the script to filter objects by prefix.

**Q: Does this replace the sync verification?**
A: No, this is complementary. Sync verification validates new uploads. Retroactive validation checks existing backups.

## Support

If you encounter issues or have questions:

1. Check Kubernetes job logs: `kubectl logs -n backups job/s3-validation-SHARE-TIMESTAMP`
2. Review validation report in S3
3. Consult the main AWS S3 backup README.md
4. Check for known issues in the repository
