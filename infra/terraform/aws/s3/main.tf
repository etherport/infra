# S3 Buckets for homelab infrastructure
#
# Buckets managed:
# - velero.wind.etherport.net - Kubernetes backups (Velero)
# - archive.wind.etherport.net - Snapshot archives (Deep Archive)
# - logs.archive.wind.etherport.net - Archive operation logs
# - email-fwd.grahamsmith.net - Email forwarding storage
# - logs.grahamsmith.net - ALB access logs and general logging
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

resource "aws_s3_bucket" "archive" {
  bucket = "archive.wind.etherport.net"

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name    = "archive.wind.etherport.net"
    Purpose = "snapshot-archives"
  }
}

resource "aws_s3_bucket_versioning" "archive" {
  bucket = aws_s3_bucket.archive.id
  versioning_configuration {
    status     = "Enabled"
    mfa_delete = "Disabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "archive" {
  bucket = aws_s3_bucket.archive.id

  rule {
    id     = "Transition to Deep Archive"
    status = "Enabled"

    filter {}

    transition {
      days          = 2
      storage_class = "DEEP_ARCHIVE"
    }
  }

  rule {
    id     = "Delete Noncurrent Versions"
    status = "Enabled"

    filter {}

    # Recovery window for accidental object deletion. Was 1 day (tight,
    # set when testing/churn was high and Deep Archive storage cost was
    # the concern). At steady state the archive bucket is write-once-
    # read-rarely; bumping to 30 days gives a real "oh no I deleted that"
    # recovery window at negligible additional cost (Deep Archive is
    # ~$1/TB/month and noncurrent versions inherit that storage class).
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
# General Logs (ALB Access Logs)
#------------------------------------------------------------------------------

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
