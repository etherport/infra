# config (cloud tag-drift detection) — AWS Config recording + aggregator.
#
# GOAL: ~100%-coverage change-tracking of every supported resource in the account
# so the tag-drift workflow can find resources NOT tagged ManagedBy=terraform
# (cloud tag drift). Chosen over the free Tagging-API approach for full coverage +
# change history. Cost target ~$2/mo: $0.003 per config item, DAILY recording, NO
# conformance packs, NO managed Config rules (the tag-finding is a FREE advanced
# query in .github/workflows/cloud-tag-drift.yml).
#
# ⚠️ CONFIG SQL CANNOT EXPRESS "MISSING A TAG" (immutable finding, see README): the
# advanced-query language has no IS NULL / NOT EXISTS / subqueries and cannot negate
# the nested `tags` array. So tag-ABSENCE is filtered CLIENT-SIDE in jq by the
# workflow — this stack just records + aggregates.
#
# SHAPE:
#  - ONE account-wide S3 bucket (this file) receives Config snapshots from BOTH
#    regions (each writes under AWSLogs/<acct>/Config/<region>/).
#  - ONE hand-rolled IAM role (this file) assumed by config.amazonaws.com in both
#    regions. NOT a service-linked role: the config.amazonaws.com SLR is account-
#    global and likely already exists (Security Hub / Control Tower / prior console
#    use) -> a hand-rolled role sidesteps an EntityAlreadyExists first-apply break.
#  - ONE account-level aggregator (this file) makes both regions queryable from one
#    place (us-west-2) via select-aggregate-resource-config (FREE).
#  - The per-region recorder + delivery_channel + recorder_status live in the
#    reusable ./modules/config-recorder submodule, invoked once per region.

locals {
  account_id  = "830881980142"
  bucket_name = "config.wind.etherport.net"
  bucket_arn  = "arn:aws:s3:::${local.bucket_name}"
  role_name   = "wind-config-recorder"
  # Config writes objects under this exact prefix; the bucket policy's PutObject
  # statement and the IAM role's delivery policy both scope to it.
  delivery_prefix = "AWSLogs/${local.account_id}/Config/*"
}

# ---------------------------------------------------------------------------
# S3 delivery bucket (account-wide singleton; both regions deliver here).
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "config" {
  bucket = local.bucket_name
  tags = {
    Name    = "AWS Config delivery bucket"
    Purpose = "config-recorder-snapshots"
  }
}

resource "aws_s3_bucket_public_access_block" "config" {
  bucket                  = aws_s3_bucket.config.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config" {
  bucket = aws_s3_bucket.config.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # SSE-S3; KMS would add per-PutObject cost + a kms grant on the role.
    }
  }
}

# Cost guard: Config snapshots accumulate forever otherwise. Expire history after
# 365d + purge incomplete multipart uploads. (Daily JSON is pennies; unbounded
# growth is the only way object storage creeps past the ~$2/mo target.)
resource "aws_s3_bucket_lifecycle_configuration" "config" {
  bucket = aws_s3_bucket.config.id
  rule {
    id     = "expire-config-history"
    status = "Enabled"
    filter {}
    expiration {
      days = 365
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ===========================================================================
# THE #1 BREAK: the S3 bucket policy for the config.amazonaws.com principal.
# Config refuses to start (delivery-channel create fails 'Insufficient delivery
# policy to S3 bucket') unless ALL of these are present:
#   - GetBucketAcl + ListBucket on the BUCKET arn
#   - PutObject on the AWSLogs/<acct>/Config/* OBJECT arn
#   - PutObject conditioned on s3:x-amz-acl = bucket-owner-full-control
#   - every statement conditioned on AWS:SourceAccount = <acct> (confused-deputy
#     guard; AWS's own console template adds it and validation expects it)
# ===========================================================================
data "aws_iam_policy_document" "config_bucket" {
  statement {
    sid       = "AWSConfigBucketPermissionsCheck"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [local.bucket_arn]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid       = "AWSConfigBucketExistenceCheck"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [local.bucket_arn]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid       = "AWSConfigBucketDelivery"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${local.bucket_arn}/${local.delivery_prefix}"]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_s3_bucket_policy" "config" {
  bucket     = aws_s3_bucket.config.id
  policy     = data.aws_iam_policy_document.config_bucket.json
  depends_on = [aws_s3_bucket_public_access_block.config]
}

# ---------------------------------------------------------------------------
# Config IAM service role (account-wide; assumed by config.amazonaws.com in both
# regions). AWS_ConfigRole (managed, the service-role/ path) grants the broad
# read/Describe/List the recorder needs; a scoped inline policy grants S3 delivery.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "recorder_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "recorder" {
  name               = local.role_name
  description        = "Assumed by config.amazonaws.com to record + deliver AWS Config snapshots (cloud tag-drift detection)."
  assume_role_policy = data.aws_iam_policy_document.recorder_assume.json
}

# MUST be the service-role/ path ARN — a bare arn:aws:iam::aws:policy/AWS_ConfigRole
# does not exist and the attach 404s. Allowed for gh-actions-terraform (the
# anti-escalation Deny only blocks AdministratorAccess / IAMFullAccess).
resource "aws_iam_role_policy_attachment" "config_managed" {
  role       = aws_iam_role.recorder.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

# Scoped S3 delivery perms (Config role -> the delivery bucket); mirrors the
# bucket policy's grant from the role side (both must agree).
data "aws_iam_policy_document" "recorder_s3" {
  statement {
    sid       = "ConfigDeliveryAcl"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [local.bucket_arn]
  }
  statement {
    sid       = "ConfigDeliveryWrite"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${local.bucket_arn}/${local.delivery_prefix}"]
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_iam_role_policy" "recorder_s3" {
  name   = "config-s3-delivery"
  role   = aws_iam_role.recorder.id
  policy = data.aws_iam_policy_document.recorder_s3.json
}

# ===========================================================================
# Per-region recorders (reusable submodule, once per region).
#  - us-west-2 (default provider) = PRIMARY: records global resource types
#    (IAM, CloudFront, etc.) — include_global_resources = true HERE only.
#  - us-east-1 = regional resources only (NO global types) so IAM is not
#    double-recorded / double-billed.
# ===========================================================================
module "recorder_usw2" {
  source                   = "./modules/config-recorder"
  recorder_name            = "wind-recorder-usw2"
  role_arn                 = aws_iam_role.recorder.arn
  s3_bucket_name           = aws_s3_bucket.config.id
  include_global_resources = true # global types (IAM/etc.) recorded HERE only

  depends_on = [
    aws_s3_bucket_policy.config,
    aws_iam_role_policy.recorder_s3,
    aws_iam_role_policy_attachment.config_managed,
  ]
}

module "recorder_use1" {
  source                   = "./modules/config-recorder"
  providers                = { aws = aws.use1 }
  recorder_name            = "wind-recorder-use1"
  role_arn                 = aws_iam_role.recorder.arn
  s3_bucket_name           = aws_s3_bucket.config.id
  include_global_resources = false # avoid double-recording global types

  depends_on = [
    aws_s3_bucket_policy.config,
    aws_iam_role_policy.recorder_s3,
    aws_iam_role_policy_attachment.config_managed,
  ]
}

# ===========================================================================
# Account-level aggregator (us-west-2) — makes BOTH regions queryable from one
# place via `aws configservice select-aggregate-resource-config` (FREE). This is
# what the cloud-tag-drift workflow queries. No conformance packs / Config rules
# -> stays entirely in the free-query tier.
# ===========================================================================
resource "aws_config_configuration_aggregator" "account" {
  name = "wind-account-aggregator"
  account_aggregation_source {
    account_ids = [local.account_id]
    regions     = ["us-west-2", "us-east-1"]
    all_regions = false
  }
}
