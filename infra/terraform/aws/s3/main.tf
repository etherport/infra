# S3 Buckets for homelab infrastructure
#
# Buckets managed:
# - velero.wind.etherport.net - Kubernetes backups (Velero specifically)
# - archive.wind.etherport.net - NAS snapshot archives (Deep Archive)
# - logs.archive.wind.etherport.net - Archive operation logs
# - email-fwd.grahamsmith.net - Email forwarding storage (kept here
#                               because the email-forward Lambda lives
#                               in this AWS account; bucket name predates
#                               the personal-web repo split and is not
#                               worth renaming)
# - logs.grahamsmith.net - General-purpose logging bucket (was ALB
#                          access logs pre-2026-05-27 ALB decom; now
#                          retained for future log sinks. Name predates
#                          the personal-web split; rename not worth the
#                          churn)
# - infra.wind.etherport.net - General-purpose homelab infra state +
#                              backups (UDM/Protect controller-DB,
#                              future Loki S3 backing, ad-hoc dumps)
#
# NOT managed (reference only):
# - terraform.wind.etherport.net - Terraform state (in use)

#------------------------------------------------------------------------------
# Velero Kubernetes Backups
#------------------------------------------------------------------------------

resource "aws_s3_bucket" "velero" {
  bucket = "velero.wind.etherport.net"

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name    = "velero.wind.etherport.net"
    Purpose = "kubernetes-backups"
  }
}

resource "aws_s3_bucket_versioning" "velero" {
  bucket = aws_s3_bucket.velero.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "velero" {
  bucket = aws_s3_bucket.velero.id

  rule {
    id     = "Delete old versions and incomplete uploads"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }

    expiration {
      expired_object_delete_marker = true
    }
  }
}

resource "aws_s3_bucket_public_access_block" "velero" {
  bucket = aws_s3_bucket.velero.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

#------------------------------------------------------------------------------
# Snapshot Archives (Deep Archive Storage)
#------------------------------------------------------------------------------

# ⚠️ USE THIS BUCKET ONLY FOR THE s3-sync ARCHIVE TASKS (cold, write-once-read-rarely).
# Its lifecycle transitions ALL objects to Glacier DEEP_ARCHIVE after 5 days, so
# retrieval takes ~12 hours. Do NOT default new backup/DR work here — anything that
# may need timely retrieval (etcd snapshots, DB dumps, app backups) gets its OWN
# STANDARD-storage bucket (see `etcd_snapshots` below and `postgres_barman`).
resource "aws_s3_bucket" "archive" {
  bucket = "archive.wind.etherport.net"

  # Object Lock — the backstop against a leaked-credential mass-delete. Was
  # enabled out-of-band on this (versioned) bucket and missing from TF; codified
  # 2026-06-23 (M101 drift review). Default retention lives in
  # aws_s3_bucket_object_lock_configuration.archive below. NB: object lock can
  # only be enabled at creation OR on an existing versioned bucket — this matches
  # the already-enabled live state (import → zero-diff), it does NOT recreate.
  object_lock_enabled = true

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name = "archive.wind.etherport.net"
    # AWS S3 tag values are char-restricted (no parens/commas/em-dash/tilde) — keep
    # this terse; the full rationale is in the comment above this resource.
    Purpose = "s3-sync-cold-storage-only-deep-archive"
  }
}

resource "aws_s3_bucket_versioning" "archive" {
  bucket = aws_s3_bucket.archive.id
  versioning_configuration {
    status     = "Enabled"
    mfa_delete = "Disabled"
  }
}

# Default Object Lock retention: GOVERNANCE / 180 days (matches live, codified
# 2026-06-23). GOVERNANCE (not COMPLIANCE) so a holder of s3:BypassGovernanceRetention
# can still purge versions for legit cleanup (e.g. the M96/M97 dedup runs) — see
# the M97 ProtectBackupObjectsFromDeletion Deny interplay. logs.archive / archive-test
# deliberately have NO object lock.
resource "aws_s3_bucket_object_lock_configuration" "archive" {
  bucket = aws_s3_bucket.archive.id

  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = 180
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "archive" {
  bucket = aws_s3_bucket.archive.id

  rule {
    id     = "Transition to Deep Archive"
    status = "Enabled"

    filter {}

    # 5-day window (was 2, 2026-06-21): now that the initial full-NAS backup is
    # done, incremental upload volume is small, so the extra few days in STANDARD
    # cost little — and the wider window leaves room to spot/correct a bad upload
    # (e.g. the iCloud Photos dedup) before objects lock into Deep Archive's
    # 180-day minimum + ~12h retrieval.
    transition {
      days          = 5
      storage_class = "DEEP_ARCHIVE"
    }
  }

  rule {
    id     = "Delete Noncurrent Versions"
    status = "Enabled"

    filter {}

    # Move superseded (noncurrent) versions to Deep Archive after 1 day. Without
    # this, the current-version `transition` above does NOT touch noncurrent
    # versions (AWS: "the Transition action applies to the current object version;
    # to manage noncurrent versions, Amazon S3 defines NoncurrentVersionTransition"),
    # so a daily-overwritten file (e.g. the iMessage chat.db on the `backups` share)
    # would leave ~180 noncurrent versions sitting in STANDARD ($0.023/GB-mo) for the
    # full 180-day Object-Lock window — ~20x more than Deep Archive ($0.00099/GB-mo;
    # ~$2.2/mo vs ~$0.1/mo for a 550MB/day file). Object Lock is MAINTAINED across
    # transitions and does NOT block them (only expiration), so the version stays
    # WORM-protected the whole time. The ~1-2 day shortfall vs Deep Archive's 180-day
    # minimum on the eventual delete is a negligible early-deletion fee.
    noncurrent_version_transition {
      noncurrent_days = 1
      storage_class   = "DEEP_ARCHIVE"
    }

    # Recovery window for accidental object deletion: keep noncurrent versions then
    # delete. NB Object Lock GOVERNANCE 180d DEFERS this expiration — a locked
    # noncurrent version is NOT removed at 30 days; lifecycle waits until its
    # retain-until (upload + 180d) passes, then deletes it. So effective retention
    # is ~180 days, spent in Deep Archive (per the transition above), not STANDARD.
    noncurrent_version_expiration {
      noncurrent_days           = 30
      newer_noncurrent_versions = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }

    expiration {
      expired_object_delete_marker = true
    }
  }
}

resource "aws_s3_bucket_public_access_block" "archive" {
  bucket = aws_s3_bucket.archive.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

#------------------------------------------------------------------------------
# Archive Operation Logs
#------------------------------------------------------------------------------

resource "aws_s3_bucket" "logs_archive" {
  bucket = "logs.archive.wind.etherport.net"

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name    = "logs.archive.wind.etherport.net"
    Purpose = "archive-logs"
  }
}

resource "aws_s3_bucket_versioning" "logs_archive" {
  bucket = aws_s3_bucket.logs_archive.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs_archive" {
  bucket = aws_s3_bucket.logs_archive.id

  rule {
    id     = "Delete old versions and incomplete uploads"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }

    expiration {
      expired_object_delete_marker = true
    }
  }
}

resource "aws_s3_bucket_public_access_block" "logs_archive" {
  bucket = aws_s3_bucket.logs_archive.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

#------------------------------------------------------------------------------
# Email Forwarding Storage
#------------------------------------------------------------------------------

resource "aws_s3_bucket" "email_fwd" {
  bucket = "email-fwd.grahamsmith.net"

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name    = "email-fwd.grahamsmith.net"
    Purpose = "email-forwarding"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "email_fwd" {
  bucket = aws_s3_bucket.email_fwd.id

  rule {
    id     = "expire-old-emails"
    status = "Enabled"

    filter {
      prefix = "emails/"
    }

    expiration {
      days = 30
    }
  }
}

resource "aws_s3_bucket_public_access_block" "email_fwd" {
  bucket = aws_s3_bucket.email_fwd.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

#------------------------------------------------------------------------------
# General Logs (legacy ALB access logs; retained for future log sinks)
#------------------------------------------------------------------------------
# Originally provisioned to receive ALB access logs. ALB was
# decommissioned 2026-05-27 (see docs/runbooks/alb-decom.md). Bucket
# retained for future use (e.g., CloudFront logs from personal-web
# distributions, ad-hoc dumps). prevent_destroy guards against drift
# sweeps deleting it.

resource "aws_s3_bucket" "logs" {
  bucket = "logs.grahamsmith.net"

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name    = "logs.grahamsmith.net"
    Purpose = "alb-access-logs"
  }
}

resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAlbAccessLogs"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::797873946194:root"
        }
        Action   = "s3:PutObject"
        Resource = "arn:aws:s3:::logs.grahamsmith.net/alb/AWSLogs/830881980142/*"
      },
      local.deny_bucket_destruction_statement_logs,
    ]
  })
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket = aws_s3_bucket.logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

#------------------------------------------------------------------------------
# Postgres Barman Backups
#
# CloudNativePG continuously archives WAL segments and runs scheduled
# full backups via Barman Cloud. Lives in its own bucket so its lifecycle
# (retention controlled by CNPG, ~30d for PITR) doesn't fight with
# Velero's. Bucket keeps the wind.etherport.net suffix because the
# backup target is a wind-cluster resource.
#------------------------------------------------------------------------------

resource "aws_s3_bucket" "postgres_barman" {
  bucket = "postgres-barman.wind.etherport.net"

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name    = "postgres-barman.wind.etherport.net"
    Purpose = "postgres-barman-backups"
  }
}

resource "aws_s3_bucket_versioning" "postgres_barman" {
  bucket = aws_s3_bucket.postgres_barman.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "postgres_barman" {
  bucket = aws_s3_bucket.postgres_barman.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "postgres_barman" {
  bucket = aws_s3_bucket.postgres_barman.id

  rule {
    id     = "Delete non-current versions and incomplete uploads"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }

    expiration {
      expired_object_delete_marker = true
    }
  }
}

resource "aws_s3_bucket_public_access_block" "postgres_barman" {
  bucket = aws_s3_bucket.postgres_barman.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

#------------------------------------------------------------------------------
# Postgres Barman IAM
#
# Dedicated user with least-privilege access to the barman bucket only.
# Access key is materialised as a TF output (sensitive) for SOPS encryption
# into platform/kubernetes/cnpg/05-barman-credentials.sops.yaml.
#------------------------------------------------------------------------------

resource "aws_iam_user" "postgres_barman" {
  name = "barman-postgres"
  path = "/services/"
  tags = {
    Purpose = "postgres-barman-backups"
  }
}

resource "aws_iam_user_policy" "postgres_barman" {
  name = "postgres-barman-s3-access"
  user = aws_iam_user.postgres_barman.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ListBucket"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation",
        ]
        Resource = aws_s3_bucket.postgres_barman.arn
      },
      {
        Sid    = "ObjectAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
        ]
        Resource = "${aws_s3_bucket.postgres_barman.arn}/*"
      },
    ]
  })
}

resource "aws_iam_access_key" "postgres_barman" {
  user = aws_iam_user.postgres_barman.name
}

#------------------------------------------------------------------------------
# etcd snapshot offsite backups (M62)
#
# Velero-independent offsite copy of the control-plane etcd snapshots that the
# `etcd-backup.yml` systemd timer writes to /var/lib/etcd-snapshots on each cp
# node. DELIBERATELY a dedicated bucket with STANDARD storage (NOT the `archive`
# bucket, which transitions to Glacier Deep Archive after 2 days — ~12h retrieval
# would prolong a control-plane outage). 30-day expiry; immediate retrieval.
#------------------------------------------------------------------------------

resource "aws_s3_bucket" "etcd_snapshots" {
  bucket = "etcd-snapshots.wind.etherport.net"

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name    = "etcd-snapshots.wind.etherport.net"
    Purpose = "etcd-snapshot-offsite-dr"
  }
}

resource "aws_s3_bucket_versioning" "etcd_snapshots" {
  bucket = aws_s3_bucket.etcd_snapshots.id
  versioning_configuration {
    status     = "Enabled"
    mfa_delete = "Disabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "etcd_snapshots" {
  bucket = aws_s3_bucket.etcd_snapshots.id

  rule {
    id     = "Expire etcd snapshots after 30 days"
    status = "Enabled"
    filter {}

    # Keep STANDARD storage class (no Deep Archive transition) so DR restores
    # are immediate. 30 days of daily ~200MB snapshots x3 nodes is a few $/mo.
    expiration {
      days = 30
    }
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_s3_bucket_public_access_block" "etcd_snapshots" {
  bucket = aws_s3_bucket.etcd_snapshots.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Tightly-scoped writer for the cp-node snapshot script: PutObject only (the
# lifecycle handles deletion). Can't read other buckets or delete — minimal
# blast radius if a cp-node disk leaks the static key.
resource "aws_iam_user" "etcd_backup" {
  name = "etcd-backup"
  path = "/services/"
  tags = {
    Purpose = "etcd-snapshot-offsite-backups"
  }
}

resource "aws_iam_user_policy" "etcd_backup" {
  name = "etcd-backup-s3-access"
  user = aws_iam_user.etcd_backup.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.etcd_snapshots.arn
      },
      {
        Sid      = "WriteObjects"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:AbortMultipartUpload"]
        Resource = "${aws_s3_bucket.etcd_snapshots.arn}/*"
      },
    ]
  })
}

resource "aws_iam_access_key" "etcd_backup" {
  user = aws_iam_user.etcd_backup.name
}

#------------------------------------------------------------------------------
# Bucket-destruction guard
#
# `lifecycle.prevent_destroy = true` only blocks `terraform destroy`. Anyone
# with AWS admin credentials (console, `aws s3 rb`, an unrelated TF state)
# bypasses it entirely. The bucket policy below denies bucket-level
# destruction at the AWS API layer — so even an admin clicking "Delete
# bucket" in the console gets AccessDenied. Reversible: edit/remove the
# policy first, then perform the destructive op.
#
# Object-level deletion is still allowed (lifecycle rules + IAM scoping
# handle that). Versioning is left manageable so TF can configure it on
# first apply; once stable, the protection here means accidentally
# disabling versioning still requires deliberately removing this policy.
#
# Applied to every `prevent_destroy = true` bucket. `logs` has its own
# pre-existing policy — its statement is folded into that via
# `local.deny_bucket_destruction_statement_logs` above.
#------------------------------------------------------------------------------

locals {
  destruction_actions = [
    "s3:DeleteBucket",
    "s3:DeleteBucketPolicy",
  ]

  # Local form for the `logs` bucket where the statement is embedded in
  # an existing aws_s3_bucket_policy resource. ARN is hard-coded because
  # the resource itself is part of the same module and the bucket is
  # already created (referencing aws_s3_bucket.logs.arn here would be
  # fine too, but locals can't depend on resources in a cycle-safe way
  # when the policy is in the same module).
  deny_bucket_destruction_statement_logs = {
    Sid       = "DenyBucketDestruction"
    Effect    = "Deny"
    Principal = "*"
    Action    = local.destruction_actions
    Resource = [
      aws_s3_bucket.logs.arn,
      "${aws_s3_bucket.logs.arn}/*",
    ]
  }
}

resource "aws_s3_bucket_policy" "velero_protect" {
  bucket = aws_s3_bucket.velero.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyBucketDestruction"
      Effect    = "Deny"
      Principal = "*"
      Action    = local.destruction_actions
      Resource = [
        aws_s3_bucket.velero.arn,
        "${aws_s3_bucket.velero.arn}/*",
      ]
    }]
  })
}

resource "aws_s3_bucket_policy" "archive_protect" {
  bucket = aws_s3_bucket.archive.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyBucketDestruction"
      Effect    = "Deny"
      Principal = "*"
      Action    = local.destruction_actions
      Resource = [
        aws_s3_bucket.archive.arn,
        "${aws_s3_bucket.archive.arn}/*",
      ]
    }]
  })
}

resource "aws_s3_bucket_policy" "logs_archive_protect" {
  bucket = aws_s3_bucket.logs_archive.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyBucketDestruction"
      Effect    = "Deny"
      Principal = "*"
      Action    = local.destruction_actions
      Resource = [
        aws_s3_bucket.logs_archive.arn,
        "${aws_s3_bucket.logs_archive.arn}/*",
      ]
    }]
  })
}

resource "aws_s3_bucket_policy" "email_fwd_protect" {
  bucket = aws_s3_bucket.email_fwd.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyBucketDestruction"
      Effect    = "Deny"
      Principal = "*"
      Action    = local.destruction_actions
      Resource = [
        aws_s3_bucket.email_fwd.arn,
        "${aws_s3_bucket.email_fwd.arn}/*",
      ]
    }]
  })
}

resource "aws_s3_bucket_policy" "postgres_barman_protect" {
  bucket = aws_s3_bucket.postgres_barman.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyBucketDestruction"
      Effect    = "Deny"
      Principal = "*"
      Action    = local.destruction_actions
      Resource = [
        aws_s3_bucket.postgres_barman.arn,
        "${aws_s3_bucket.postgres_barman.arn}/*",
      ]
    }]
  })
}

#------------------------------------------------------------------------------
# Infrastructure state + backups (general-purpose)
#
# UDM/Protect controller-DB nightly backups (M31), and earmarked as the
# Loki S3 backing store (M37 future). Any future "where do we put this
# small infra state" question lands here unless it has a dedicated reason
# to live elsewhere.
#------------------------------------------------------------------------------

resource "aws_s3_bucket" "infra" {
  bucket = "infra.wind.etherport.net"

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name    = "infra.wind.etherport.net"
    Purpose = "homelab-infrastructure-state"
  }
}

resource "aws_s3_bucket_versioning" "infra" {
  bucket = aws_s3_bucket.infra.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "infra" {
  bucket = aws_s3_bucket.infra.id

  rule {
    id     = "Expire old object versions + abort stuck uploads"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
    expiration {
      expired_object_delete_marker = true
    }
  }

  # UDM backup objects: keep 90 days. Lifecycle rule per-prefix.
  rule {
    id     = "Expire UDM backups after 90 days"
    status = "Enabled"
    filter {
      prefix = "unifi/"
    }
    expiration {
      days = 90
    }
  }
}

resource "aws_s3_bucket_public_access_block" "infra" {
  bucket = aws_s3_bucket.infra.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "infra_protect" {
  bucket = aws_s3_bucket.infra.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyBucketDestruction"
      Effect    = "Deny"
      Principal = "*"
      Action    = local.destruction_actions
      Resource = [
        aws_s3_bucket.infra.arn,
        "${aws_s3_bucket.infra.arn}/*",
      ]
    }]
  })
}

# IAM policy update: extend the existing s3-backup-kubernetes-policy
# (attached to the kubernetes-s3-backup IAM user that backs the
# aws-backup-credentials K8s secret) to include the new infra bucket.
#
# IMPORTANT: this policy is NOT TF-managed today (was created out of
# band via aws CLI; current version is v13). Until imported, applying
# this resource via TF would create a NEW policy with the same name —
# AWS would error. Updates to the live policy need to go via:
#   aws iam create-policy-version --policy-arn arn:aws:iam::830881980142:policy/s3-backup-kubernetes-policy \
#     --policy-document file://infra/terraform/aws/iam-policies/s3-backup-kubernetes-policy.json \
#     --set-as-default
#
# A companion JSON at infra/terraform/aws/iam-policies/s3-backup-kubernetes-policy.json
# captures the desired policy text. Updating that file + running the
# CLI above is the durable workflow until someone imports the policy
# into TF state.

# =============================================================================
# Cue media storage — bug screenshots now, workout photos/video next.
# Private (ALL public access blocked), SSE-S3 at rest, versioned; the
# bug_screenshot/ prefix is pruned after 90d. Written by cue-api via the
# wind-irsa-cue-media IRSA role (infra/terraform/aws/cluster-irsa) — no static
# keys. NB dotted bucket name matches the other app buckets (SDK path-style).
# =============================================================================
resource "aws_s3_bucket" "cue_media" {
  bucket = "cue-media.etherport.net"

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name    = "cue-media.etherport.net"
    Purpose = "cue-media"
  }
}

resource "aws_s3_bucket_public_access_block" "cue_media" {
  bucket                  = aws_s3_bucket.cue_media.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cue_media" {
  bucket = aws_s3_bucket.cue_media.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "cue_media" {
  bucket = aws_s3_bucket.cue_media.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cue_media" {
  bucket = aws_s3_bucket.cue_media.id

  # Prune bug screenshots ~90d after upload (transient triage artifacts), plus
  # their old versions shortly after. Workout media (other prefixes) is retained.
  rule {
    id     = "prune-bug-screenshots-90d"
    status = "Enabled"
    filter {
      prefix = "bug_screenshot/"
    }
    expiration {
      days = 90
    }
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }

  # Housekeeping: drop failed/incomplete multipart uploads bucket-wide.
  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}
