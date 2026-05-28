# Terraform Remote State with S3 + DynamoDB

**Date**: 2025-12-31
**Context**: Migrating from local Terraform state to remote S3 backend
**Status**: ✅ Implemented (2025-12-31)

---

## Overview

Terraform state files track the current state of your infrastructure. By default, Terraform uses a local file (`terraform.tfstate`), but this has serious limitations for production use.

**Remote state backends** store state files remotely and provide:
- **Collaboration**: Multiple team members can work on the same infrastructure
- **State locking**: Prevents concurrent modifications that could corrupt state
- **Versioning**: State file history for rollback/audit
- **Encryption**: State files can contain sensitive data
- **Backup**: Automatic versioning protects against accidental deletion

---

## Current State (Local Backend)

**Location**: `/Users/grahamsmith/Projects/homelab-infra/infra/terraform/proxmox/k8s-vms/`

**Current files**:
```
terraform.tfstate         ← Current state (gitignored)
terraform.tfstate.backup  ← Previous state (gitignored)
```

**Configuration**: Implicit local backend (no `backend` block in code)

### Problems with Local State

1. **Single point of failure**: State exists only on your laptop
   - If you lose this file, Terraform loses track of your infrastructure
   - Must manually recreate state or risk destroying/recreating resources

2. **No collaboration**: Other team members can't safely apply changes
   - Each person has their own local state
   - Leads to state divergence and conflicts

3. **No locking**: Concurrent `terraform apply` from same machine could corrupt state
   - Easy to accidentally run multiple terminals
   - No protection against "apply while apply is running"

4. **No encryption at rest**: State file contains sensitive data in plaintext
   - IP addresses, resource IDs, sometimes passwords/keys
   - Stored unencrypted on local disk

5. **No audit trail**: Can't see who made what changes when
   - State changes aren't logged
   - Hard to debug "who changed this?"

6. **No versioning**: Only one backup file kept
   - Can't roll back to state from 2 weeks ago
   - Accidental corruption requires manual recovery

---

## Recommended Solution: S3 + DynamoDB Backend

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Terraform CLI (local machine)                               │
│ terraform apply                                             │
└────────┬────────────────────────────────────────────────────┘
         │
         │ 1. Acquire lock in DynamoDB
         │ 2. Read state from S3
         │ 3. Plan changes
         │ 4. Apply changes
         │ 5. Write new state to S3
         │ 6. Release lock
         ▼
┌─────────────────────────────────────────────────────────────┐
│ AWS S3 Bucket (State Storage)                               │
│ Name: homelab-terraform-state                               │
│                                                             │
│ ├── proxmox/k8s-vms/terraform.tfstate (current)            │
│ ├── proxmox/k8s-vms/terraform.tfstate (version 2)          │
│ ├── proxmox/k8s-vms/terraform.tfstate (version 1)          │
│ └── ... (versioned history)                                │
│                                                             │
│ Features:                                                   │
│ ✓ Versioning enabled (state history)                       │
│ ✓ Encryption: AES256 or KMS                                │
│ ✓ Lifecycle: Keep 30 days of versions, then delete         │
│ ✓ Private: Block public access                             │
└─────────────────────────────────────────────────────────────┘
         │
         │ Lock/Unlock
         ▼
┌─────────────────────────────────────────────────────────────┐
│ DynamoDB Table (State Locking)                              │
│ Name: homelab-terraform-locks                               │
│                                                             │
│ ┌─────────────────────────────────────────────────────┐   │
│ │ LockID (String, Primary Key)                        │   │
│ ├─────────────────────────────────────────────────────┤   │
│ │ homelab-infra/proxmox/k8s-vms                       │   │
│ │   Info: {"Operation":"OperationTypeApply",...}      │   │
│ │   Who: graham@hostname                              │   │
│ │   Created: 2025-12-31T10:15:00Z                     │   │
│ └─────────────────────────────────────────────────────┘   │
│                                                             │
│ Features:                                                   │
│ ✓ Pay-per-request billing (cheap for infrequent use)       │
│ ✓ Strong consistency (required for locking)                │
│ ✓ Automatic lock expiration (prevents stuck locks)         │
└─────────────────────────────────────────────────────────────┘
```

### How State Locking Works

**Scenario**: Two people run `terraform apply` at the same time

```
Person A (10:00:00)          DynamoDB Lock Table          Person B (10:00:02)
─────────────────────────────────────────────────────────────────────────────
terraform apply
  │
  ├─→ Try to acquire lock
  │   Create item in DynamoDB:
  │   LockID="homelab/proxmox/k8s-vms"
  │
  ├─→ Lock acquired! ✅
  │   Reading state from S3...
  │   Planning changes...
  │   Applying...
  │                                                        terraform apply
  │                                                          │
  │                                                          ├─→ Try to acquire lock
  │                                                          │   Item already exists!
  │                                                          │
  │                                                          ├─→ Lock acquisition FAILED ❌
  │                                                          │
  │                                                          └─→ Error: state locked
  │                                                              Lock Info:
  │                                                                ID: abc-123
  │                                                                Who: graham@laptop
  │                                                                Created: 10:00:00
  │
  ├─→ Apply complete
  │   Writing new state to S3...
  │
  └─→ Release lock
      Delete item from DynamoDB

                                                             Person B waits, then:
                                                             terraform apply (retry)
                                                               │
                                                               ├─→ Try to acquire lock
                                                               │   No existing lock
                                                               │
                                                               └─→ Lock acquired! ✅
                                                                   (proceeds safely)
```

### Benefits of S3 + DynamoDB

#### 1. **Team Collaboration** ✅
Multiple team members can work on infrastructure safely:
- Everyone references the same state file
- Changes are always based on latest state
- No state file conflicts

#### 2. **State Locking** ✅
Prevents concurrent modifications:
- DynamoDB provides distributed lock
- `terraform apply` blocks if lock is held
- Protects against race conditions and corruption

#### 3. **State Versioning** ✅
S3 versioning keeps history of all state changes:
- Can retrieve state from any point in time
- Recover from accidental corruption
- Audit trail of infrastructure changes

#### 4. **Encryption** ✅
State files contain sensitive data (IPs, resource IDs):
- S3 server-side encryption (AES256 or KMS)
- Data encrypted at rest
- Data encrypted in transit (HTTPS)

#### 5. **Durability** ✅
S3 provides 99.999999999% (11 9's) durability:
- Automatic replication across multiple AZs
- No risk of laptop failure losing state
- Backed up automatically

#### 6. **Cost-Effective** 💰
For small-scale homelab usage:
- S3 storage: ~$0.023/GB/month (state files are KB-sized)
- DynamoDB: Pay-per-request (~$0.000001 per request)
- **Estimated monthly cost: < $0.50**

---

## Implementation Guide

### Prerequisites

- AWS account with appropriate credentials
- AWS CLI configured (`aws configure`)
- Terraform >= 1.4.0 installed

### Step 1: Create S3 Bucket for State

**Option A: Via AWS Console**
1. Go to S3 console
2. Create bucket: `homelab-terraform-state`
3. Region: `us-west-2` (match your existing AWS resources)
4. Block public access: ✅ Enabled (all checkboxes)
5. Versioning: ✅ Enabled
6. Encryption: ✅ Enable (AES-256 or KMS)
7. Create bucket

**Option B: Via AWS CLI** (recommended for IaC approach):
```bash
# Create bucket
aws s3api create-bucket \
  --bucket homelab-terraform-state \
  --region us-west-2 \
  --create-bucket-configuration LocationConstraint=us-west-2

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket homelab-terraform-state \
  --versioning-configuration Status=Enabled

# Enable encryption (AES256)
aws s3api put-bucket-encryption \
  --bucket homelab-terraform-state \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }'

# Block public access
aws s3api put-public-access-block \
  --bucket homelab-terraform-state \
  --public-access-block-configuration \
    BlockPublicAcls=true,\
    IgnorePublicAcls=true,\
    BlockPublicPolicy=true,\
    RestrictPublicBuckets=true

# Add lifecycle rule (optional: keep 30 days of old versions)
aws s3api put-bucket-lifecycle-configuration \
  --bucket homelab-terraform-state \
  --lifecycle-configuration '{
    "Rules": [{
      "Id": "ExpireOldVersions",
      "Status": "Enabled",
      "NoncurrentVersionExpiration": {
        "NoncurrentDays": 30
      }
    }]
  }'
```

### Step 2: Create DynamoDB Table for Locking

**Via AWS CLI**:
```bash
aws dynamodb create-table \
  --table-name homelab-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-west-2
```

**Key details**:
- **Table name**: `homelab-terraform-locks` (can be anything, but this is conventional)
- **Primary key**: `LockID` (String) - **Must be exactly this name**
- **Billing mode**: `PAY_PER_REQUEST` (cheaper for low-volume usage)

**Verify table creation**:
```bash
aws dynamodb describe-table \
  --table-name homelab-terraform-locks \
  --region us-west-2 \
  --query 'Table.TableStatus'
# Should return: "ACTIVE"
```

### Step 3: Configure Terraform Backend

**Create new file**: `/Users/grahamsmith/Projects/homelab-infra/infra/terraform/proxmox/k8s-vms/backend.tf`

```hcl
terraform {
  backend "s3" {
    # S3 bucket for state storage
    bucket = "homelab-terraform-state"
    key    = "proxmox/k8s-vms/terraform.tfstate"
    region = "us-west-2"

    # DynamoDB table for state locking
    dynamodb_table = "homelab-terraform-locks"

    # Encryption
    encrypt = true

    # Optional: Use specific AWS profile if not using default
    # profile = "homelab"
  }
}
```

**Key parameter**: `key = "proxmox/k8s-vms/terraform.tfstate"`
- This is the **path within the S3 bucket** where state will be stored
- Allows organizing multiple Terraform projects in same bucket:
  ```
  s3://homelab-terraform-state/
  ├── proxmox/k8s-vms/terraform.tfstate        ← This project
  ├── proxmox/other-vms/terraform.tfstate      ← Future project
  └── aws/networking/terraform.tfstate         ← Future project
  ```

### Step 4: Migrate Local State to S3

**IMPORTANT**: This is a one-time migration. Terraform will copy your existing local state to S3.

```bash
cd /Users/grahamsmith/Projects/homelab-infra/infra/terraform/proxmox/k8s-vms/

# Initialize backend (will prompt to migrate)
terraform init

# You'll see:
#
# Initializing the backend...
# Do you want to copy existing state to the new backend?
#   Pre-existing state was found while migrating the previous "local" backend to the
#   newly configured "s3" backend. No existing state was found in the newly
#   configured "s3" backend. Do you want to copy this state to the new "s3"
#   backend? Enter "yes" to copy and "no" to start with an empty state.
#
# Enter a value: yes

# Type: yes
```

**What happens**:
1. Terraform reads your local `terraform.tfstate`
2. Uploads it to S3 at `s3://homelab-terraform-state/proxmox/k8s-vms/terraform.tfstate`
3. Creates initial version in S3
4. Updates `.terraform/terraform.tfstate` to point to remote backend
5. **Local state file remains** (as backup) but is no longer used

### Step 5: Verify Migration

**Check S3**:
```bash
aws s3 ls s3://homelab-terraform-state/proxmox/k8s-vms/
# Should show: terraform.tfstate

# View state file metadata
aws s3api head-object \
  --bucket homelab-terraform-state \
  --key proxmox/k8s-vms/terraform.tfstate
```

**Check local Terraform config**:
```bash
cat .terraform/terraform.tfstate
```

Should show:
```json
{
  "version": 3,
  "serial": 1,
  "lineage": "...",
  "backend": {
    "type": "s3",
    "config": {
      "bucket": "homelab-terraform-state",
      ...
    }
  }
}
```

**Test locking**:
```bash
# In one terminal:
terraform plan  # Acquires lock

# In another terminal (while first is running):
terraform plan  # Should show lock error with details
```

### Step 6: Backup and Cleanup

**Backup local state** (just in case):
```bash
# Create backup directory
mkdir -p ~/.terraform-state-backups/k8s-vms-migration-$(date +%Y%m%d)

# Copy local state files
cp terraform.tfstate* ~/.terraform-state-backups/k8s-vms-migration-$(date +%Y%m%d)/
```

**Local state files can now be deleted** (optional, but recommended to avoid confusion):
```bash
# The backend is now remote, these local files are no longer used
rm terraform.tfstate terraform.tfstate.backup
```

---

## Day-to-Day Usage

### Running Terraform Commands

**No change to workflow!** Commands work exactly the same:

```bash
terraform plan
terraform apply
terraform destroy
```

Terraform automatically:
1. Acquires lock in DynamoDB before operations
2. Reads state from S3
3. Performs operation
4. Writes updated state to S3
5. Releases lock

### Working with Team Members

**Scenario**: Teammate wants to work on infrastructure

1. **Clone repo**:
   ```bash
   git clone https://github.com/sparked-diamond/infra.git
   cd infra/infra/terraform/proxmox/k8s-vms/
   ```

2. **Initialize Terraform** (downloads backend config):
   ```bash
   terraform init
   ```

   Terraform automatically:
   - Connects to S3 backend
   - Downloads current state
   - Ready to work!

3. **No manual state file sharing needed** ✅

### Viewing State History

**List all versions**:
```bash
aws s3api list-object-versions \
  --bucket homelab-terraform-state \
  --prefix proxmox/k8s-vms/terraform.tfstate
```

**Download specific version**:
```bash
aws s3api get-object \
  --bucket homelab-terraform-state \
  --key proxmox/k8s-vms/terraform.tfstate \
  --version-id <VERSION_ID> \
  old-state.tfstate
```

**Restore old version** (if needed):
```bash
# WARNING: This overwrites current state - use with caution!
terraform state push old-state.tfstate
```

### Handling Lock Issues

**Scenario**: Lock is stuck (e.g., process killed mid-apply)

```bash
# Force unlock (use with extreme caution!)
terraform force-unlock <LOCK_ID>

# Lock ID is shown in error message when lock acquisition fails
```

**Better approach**: Delete lock from DynamoDB manually:
```bash
aws dynamodb delete-item \
  --table-name homelab-terraform-locks \
  --key '{"LockID":{"S":"homelab-terraform-state/proxmox/k8s-vms/terraform.tfstate-md5"}}'
```

---

## Cost Estimation

### S3 Storage Costs

**Assumptions**:
- State file size: ~50 KB (typical for small infrastructure)
- Versions kept: 30 (1 month with daily changes)
- Total storage: 50 KB × 30 = 1.5 MB

**Monthly cost**:
```
S3 Standard storage: $0.023 per GB/month
1.5 MB = 0.0015 GB
0.0015 GB × $0.023 = $0.00003 per month
```

**Negligible** (< $0.01/month)

### DynamoDB Costs

**Assumptions**:
- Operations per month: ~100 (terraform plan/apply runs)
- Pay-per-request pricing

**Monthly cost**:
```
Write requests: $1.25 per million writes
Read requests: $0.25 per million reads
100 operations = 100 reads + 100 writes
(100 × 2) / 1,000,000 × $0.75 = $0.00015 per month
```

**Negligible** (< $0.01/month)

### Total Monthly Cost

**~$0.01 - $0.50 per month** (depending on usage patterns)

---

## Security Considerations

### State File Encryption

**S3 encryption options**:

1. **AES-256 (SSE-S3)** - Recommended for homelab:
   - AWS-managed keys
   - Transparent encryption/decryption
   - No additional cost
   - Simpler setup

2. **KMS (SSE-KMS)** - For enhanced security:
   - Customer-managed keys
   - Audit trail via CloudTrail
   - Access control via IAM
   - Small additional cost (~$1/month for key)

**Current recommendation**: Start with AES-256, upgrade to KMS if needed.

### IAM Permissions

**Minimum required permissions for Terraform user**:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket"
      ],
      "Resource": "arn:aws:s3:::homelab-terraform-state"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": "arn:aws:s3:::homelab-terraform-state/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:DeleteItem"
      ],
      "Resource": "arn:aws:dynamodb:us-west-2:*:table/homelab-terraform-locks"
    }
  ]
}
```

### Access Logging (optional)

**Enable S3 access logging** for audit trail:

```bash
# Create logging bucket
aws s3api create-bucket \
  --bucket homelab-terraform-state-logs \
  --region us-west-2

# Enable logging on state bucket
aws s3api put-bucket-logging \
  --bucket homelab-terraform-state \
  --bucket-logging-status '{
    "LoggingEnabled": {
      "TargetBucket": "homelab-terraform-state-logs",
      "TargetPrefix": "state-access-logs/"
    }
  }'
```

---

## Troubleshooting

### "Error acquiring the state lock"

**Symptom**:
```
Error: Error acquiring the state lock

Error message: ConditionalCheckFailedException: The conditional request failed
Lock Info:
  ID:        abc123-def456-...
  Path:      homelab-terraform-state/proxmox/k8s-vms/terraform.tfstate
  Operation: OperationTypeApply
  Who:       graham@laptop
  Version:   1.5.0
  Created:   2025-12-31 10:15:00.123 +0000 UTC
```

**Causes**:
1. Another terraform process is running (wait for it to finish)
2. Previous process was killed/crashed (lock left stuck)

**Solutions**:
```bash
# Option 1: Wait for other process to finish

# Option 2: Force unlock (if you're SURE no other process is running)
terraform force-unlock abc123-def456-...

# Option 3: Manually delete lock from DynamoDB
aws dynamodb delete-item \
  --table-name homelab-terraform-locks \
  --key '{"LockID":{"S":"homelab-terraform-state/proxmox/k8s-vms/terraform.tfstate-md5"}}'
```

### "NoSuchBucket: The specified bucket does not exist"

**Symptom**:
```
Error: Failed to get existing workspaces: S3 bucket does not exist.
```

**Cause**: S3 bucket not created, or wrong bucket name in `backend.tf`

**Solution**:
```bash
# Verify bucket exists
aws s3 ls s3://homelab-terraform-state

# If not, create it (see Step 1)
```

### "AccessDenied" errors

**Symptom**:
```
Error: error using credentials to get account ID: error calling sts:GetCallerIdentity: AccessDenied
```

**Cause**: AWS credentials not configured or insufficient permissions

**Solution**:
```bash
# Verify AWS credentials
aws sts get-caller-identity

# Check IAM permissions (see Security Considerations section)
```

---

## Migration Rollback (if needed)

**Scenario**: Need to go back to local state for some reason

### Step 1: Download state from S3

```bash
cd /Users/grahamsmith/Projects/homelab-infra/infra/terraform/proxmox/k8s-vms/

# Download current state
aws s3 cp s3://homelab-terraform-state/proxmox/k8s-vms/terraform.tfstate ./terraform.tfstate
```

### Step 2: Remove backend configuration

```bash
# Comment out or delete backend.tf
mv backend.tf backend.tf.disabled
```

### Step 3: Re-initialize with local backend

```bash
terraform init -migrate-state

# When prompted:
# "Do you want to copy existing state from the "s3" backend?"
# Enter: yes
```

### Step 4: Verify

```bash
terraform plan
# Should work with local state
```

---

## References

- [Terraform S3 Backend Documentation](https://www.terraform.io/docs/language/settings/backends/s3.html)
- [AWS S3 Versioning](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Versioning.html)
- [DynamoDB for Terraform State Locking](https://www.terraform.io/docs/language/settings/backends/s3.html#dynamodb-state-locking)
- [Terraform State Best Practices](https://www.terraform.io/docs/language/state/remote.html)

---

## Implementation Details

**Implemented**: 2025-12-31
**Updated**: 2026-04-07

**Resources Created**:
- **S3 Bucket**: `terraform.wind.etherport.net`
  - Region: us-west-2
  - Versioning: Enabled
  - Encryption: AES-256
  - Lifecycle: Expire noncurrent versions after 30 days
- ~~**DynamoDB Table**: `homelab-terraform-locks`~~ **DEPRECATED** - Deleted 2026-04
  - Replaced with S3 native locking (`use_lockfile = true`)
  - DynamoDB no longer needed for state locking with AWS provider >= 5.x
- **IAM User**: `terraform-homelab`
  - Access: Programmatic only
  - Policies: Multiple module-specific policies (see `iam-policies/` directory)
- **AWS Profile**: `homelab`

**Current State Paths** (all modules use S3-native locking):

| Module | State Path |
|--------|------------|
| Proxmox VMs | `proxmox/k8s-vms/terraform.tfstate` |
| AWS Networking | `aws/networking/terraform.tfstate` |
| AWS Compute | `aws/compute/terraform.tfstate` |
| AWS ACM | `aws/acm/terraform.tfstate` |
| AWS S3 | `aws/s3/terraform.tfstate` |
| AWS SES | `aws/ses/terraform.tfstate` |
| Lambda Modules | `aws/<module>/terraform.tfstate` |
| Cloudflare (etherport.net) | `cloudflare/terraform.tfstate` |

> **Removed paths** (state objects still exist in S3 for audit; modules deleted):
> - `aws/load-balancing/terraform.tfstate` — ALB decom 2026-05-27 (see `docs/runbooks/alb-decom.md`)
> - `aws/route53/terraform.tfstate` — Route53 → CF migration 2026-05-25
> - `cloudflare-personal/terraform.tfstate` — split out to the personal-web repo 2026-05-27

---

**Last Updated**: 2026-05-27
**Status**: ✅ Implemented and verified (S3-native locking)
