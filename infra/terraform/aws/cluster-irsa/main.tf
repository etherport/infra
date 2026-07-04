# cluster-irsa (M75) — in-cluster workload identity for AWS access.
#
# Replaces the long-lived static IAM keys that in-cluster workloads (velero, the
# s3-sync/rclone backup jobs, CNPG barman, ai-advisor, cloudwatch-to-loki) carry
# in K8s Secrets/etcd with short-lived, per-pod credentials minted via
# AssumeRoleWithWebIdentity (IRSA). Same standing-credential class H29 killed in
# CI and M71 targets on the mini — extended INTO the cluster.
#
# This is the self-hosted (non-EKS) IRSA pattern: the cluster's OIDC discovery doc
# + JWKS are published to a PUBLIC S3 bucket (the only public-read objects in the
# account), and that bucket URL is registered as an IAM OIDC provider. The
# kube-apiserver's --service-account-issuer is set to the same URL (M75 Phase 3),
# so pod projected SA tokens carry iss=<bucket-url>; AWS STS fetches the discovery
# + keys from the bucket to validate them.
#
# Apply order (see README): this stack (provider + bucket + roles) is created
# FIRST and is harmless until (a) the apiserver issuer is flipped and (b) a SA is
# annotated with a role ARN — so it can ship well ahead of the disruptive Phase 3.

locals {
  account_id = "830881980142"
  region     = "us-west-2"

  # Dotless, account-suffixed bucket so the virtual-hosted-style URL
  # <bucket>.s3.<region>.amazonaws.com stays a SINGLE label under the
  # *.s3.<region>.amazonaws.com wildcard cert (a dotted bucket name would break
  # TLS for the issuer URL).
  oidc_bucket = "wind-cluster-oidc-830881980142"
  issuer_host = "${local.oidc_bucket}.s3.${local.region}.amazonaws.com"
  issuer_url  = "https://${local.issuer_host}"

  # Workload -> {trusted SA subjects, least-priv inline policy}. One role per
  # workload group; trust is locked to the exact namespace/ServiceAccount (the
  # s3-sync group uses a prefix wildcard since all its jobs share one bucket
  # scope). Policies mirror the scopes the static keys carry today.
  roles = {
    velero = {
      subs = ["system:serviceaccount:velero:velero-server"]
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid      = "ListVeleroBucket"
            Effect   = "Allow"
            Action   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"]
            Resource = "arn:aws:s3:::velero.wind.etherport.net"
          },
          {
            Sid      = "VeleroObjects"
            Effect   = "Allow"
            Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
            Resource = "arn:aws:s3:::velero.wind.etherport.net/*"
          },
        ]
      })
    }

    # All backups-namespace S3 jobs (rclone s3-sync archive/backups/content/
    # graham/mark/media/scans, plus unifi-backup + the daily-report summary).
    # Scope == the existing s3-backup-kubernetes-policy (archive / logs.archive /
    # archive-test / infra), kept as the single source of truth.
    s3-sync = {
      subs = [
        # Matches the bare `s3-sync` SA (approval-server + validation jobs) AND the
        # per-share `s3-sync-<share>-s3-sync` SAs (kustomize namePrefix).
        "system:serviceaccount:backups:s3-sync*",
        "system:serviceaccount:backups:unifi-backup",
        "system:serviceaccount:backups:daily-report",
      ]
      policy = file("${path.module}/../iam-policies/s3-backup-kubernetes-policy.json")
    }

    # Both CNPG clusters (postgres-cluster + cue-db) back up via Barman to the one
    # postgres-barman bucket (CNPG namespaces objects under per-server prefixes).
    barman = {
      subs = [
        "system:serviceaccount:postgres:postgres-cluster",
        "system:serviceaccount:cue:cue-db",
      ]
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid      = "ListBarmanBucket"
            Effect   = "Allow"
            Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
            Resource = "arn:aws:s3:::postgres-barman.wind.etherport.net"
          },
          {
            Sid      = "BarmanObjects"
            Effect   = "Allow"
            Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
            Resource = "arn:aws:s3:::postgres-barman.wind.etherport.net/*"
          },
        ]
      })
    }

    # cue-api media bucket (bug screenshots now; workout photos/video next). RW on
    # the cue-media bucket ONLY — mirror of the barman role shape. cue-api assumes
    # this via the cue:cue-api SA's web-identity token (no static keys).
    cue-media = {
      subs = ["system:serviceaccount:cue:cue-api"]
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid      = "ListCueMediaBucket"
            Effect   = "Allow"
            Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
            Resource = "arn:aws:s3:::cue-media.etherport.net"
          },
          {
            Sid      = "CueMediaObjects"
            Effect   = "Allow"
            Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
            Resource = "arn:aws:s3:::cue-media.etherport.net/*"
          },
        ]
      })
    }

    # ai-advisor (auto-remediation) + cloudwatch-to-loki: read-only CloudWatch
    # Logs. Mirrors the ai-advisor-readonly user scope (Lambda + EC2-agent groups).
    cloudwatch-read = {
      subs = [
        "system:serviceaccount:auto-remediation:remediation-controller",
        "system:serviceaccount:cloudwatch-to-loki:cloudwatch-to-loki",
        # service-status-report (monitoring) sends its daily email via SES API on
        # this role (it does not read CloudWatch; reuses the role for the SES grant).
        "system:serviceaccount:monitoring:service-status-report",
      ]
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid      = "DescribeLogGroups"
            Effect   = "Allow"
            Action   = ["logs:DescribeLogGroups", "logs:DescribeLogStreams"]
            Resource = "*"
          },
          {
            Sid    = "ReadLogs"
            Effect = "Allow"
            Action = ["logs:GetLogEvents", "logs:FilterLogEvents", "logs:StartQuery", "logs:GetQueryResults"]
            Resource = [
              "arn:aws:logs:*:*:log-group:/aws/lambda/*",
              "arn:aws:logs:*:*:log-group:/aws/lambda/*:log-stream:*",
              "arn:aws:logs:*:*:log-group:/aws/ec2/*",
              "arn:aws:logs:*:*:log-group:/aws/ec2/*:log-stream:*",
              "arn:aws:logs:*:*:log-group:CloudWatchAgent*",
              "arn:aws:logs:*:*:log-group:CloudWatchAgent*:log-stream:*",
            ]
          },
        ]
      })
    }
  }
}

# ---------------------------------------------------------------------------
# Public OIDC discovery bucket — holds ONLY the two public-read OIDC metadata
# objects. Everything else in the account stays private.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "oidc" {
  bucket = local.oidc_bucket
  # NB: S3 bucket tag VALUES are char-restricted — no parens/commas/em-dash/tilde.
  tags = {
    Name    = "cluster OIDC discovery"
    Purpose = "irsa-oidc-discovery"
  }
}

# Public bucket policy needs block_public_policy / restrict_public_buckets OFF.
# ACL-based public access stays blocked — we grant read via the bucket policy.
resource "aws_s3_bucket_public_access_block" "oidc" {
  bucket                  = aws_s3_bucket.oidc.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}

data "aws_iam_policy_document" "oidc_public_read" {
  statement {
    sid    = "PublicReadOIDCDiscovery"
    effect = "Allow"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions = ["s3:GetObject"]
    resources = [
      "${aws_s3_bucket.oidc.arn}/.well-known/openid-configuration",
      "${aws_s3_bucket.oidc.arn}/keys.json",
    ]
  }
}

resource "aws_s3_bucket_policy" "oidc" {
  bucket     = aws_s3_bucket.oidc.id
  policy     = data.aws_iam_policy_document.oidc_public_read.json
  depends_on = [aws_s3_bucket_public_access_block.oidc]
}

# OIDC discovery document. issuer/jwks_uri are derived from locals so they always
# match the IAM provider URL and the apiserver --service-account-issuer.
resource "aws_s3_object" "discovery" {
  bucket       = aws_s3_bucket.oidc.id
  key          = ".well-known/openid-configuration"
  content_type = "application/json"
  content = jsonencode({
    issuer                                = local.issuer_url
    jwks_uri                              = "${local.issuer_url}/keys.json"
    authorization_endpoint                = "urn:kubernetes:programmatic_authorization"
    response_types_supported              = ["id_token"]
    subject_types_supported               = ["public"]
    id_token_signing_alg_values_supported = ["RS256"]
    claims_supported                      = ["sub", "iss"]
  })
}

# JWKS = the cluster's public SA signing keys, copied verbatim from
# `kubectl get --raw /openid/v1/jwks`. Public keys only — safe to host publicly
# (the apiserver already serves them anonymously). Re-sync this file ONLY if the
# SA signing key (sa.key) is ever rotated.
resource "aws_s3_object" "keys" {
  bucket       = aws_s3_bucket.oidc.id
  key          = "keys.json"
  content_type = "application/json"
  content      = file("${path.module}/keys.json")
  etag         = filemd5("${path.module}/keys.json")
}

# ---------------------------------------------------------------------------
# IAM OIDC provider for the cluster issuer. The thumbprint is the S3 endpoint's
# root-CA SHA1 fingerprint, computed live so it tracks AWS cert-chain changes.
# ---------------------------------------------------------------------------
data "tls_certificate" "oidc" {
  url = local.issuer_url
}

resource "aws_iam_openid_connect_provider" "cluster" {
  url             = local.issuer_url
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[length(data.tls_certificate.oidc.certificates) - 1].sha1_fingerprint]
  tags = {
    Name = "wind cluster IRSA issuer"
  }
}

# ---------------------------------------------------------------------------
# Per-workload roles + inline least-priv policies.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "trust" {
  for_each = local.roles
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.cluster.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "${local.issuer_host}:sub"
      values   = each.value.subs
    }
  }
}

resource "aws_iam_role" "irsa" {
  for_each             = local.roles
  name                 = "wind-irsa-${each.key}"
  description          = "IRSA role assumed by the ${each.key} workload(s) via cluster OIDC (M75). Short-lived creds, no static keys."
  assume_role_policy   = data.aws_iam_policy_document.trust[each.key].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "irsa" {
  for_each = local.roles
  name     = "wind-irsa-${each.key}"
  role     = aws_iam_role.irsa[each.key].id
  policy   = each.value.policy
}

# The s3-sync family also sends email via the SES API (`aws ses send-email`): the
# daily-report summary + the delete-guard approval link. The old kubernetes-s3-backup
# static user carried this; the IRSA migration missed it → daily-report + approval
# emails failed `AccessDenied ses:SendEmail` (2026-06-25). Scoped to the etherport.net
# identity. (ai-advisor/alertmanager email via SES *SMTP* with static creds, not this.)
# ai-advisor (+ service-status-report, whose SA is added to this role's trust) send
# their emails via the SES API (boto3 / aws CLI) on the cloudwatch-read role —
# replacing static SES SMTP creds (email-transport consolidation). Same v1 SendEmail
# Resource:"*" caveat as s3-sync.
# H46 (2026-07-03): the watchdog-deadman CronJob publishes a heartbeat metric.
# Scoped to the custom namespace only — PutMetricData cannot be resource-scoped,
# but the cloudwatch:namespace condition pins it to Wind/Deadman.
resource "aws_iam_role_policy" "cloudwatch_read_putmetric" {
  name = "wind-deadman-putmetric"
  role = aws_iam_role.irsa["cloudwatch-read"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["cloudwatch:PutMetricData"]
      Resource = "*"
      Condition = { StringEquals = { "cloudwatch:namespace" = "Wind/Deadman" } }
    }]
  })
}

resource "aws_iam_role_policy" "cloudwatch_read_ses" {
  name = "wind-irsa-cloudwatch-read-ses"
  role = aws_iam_role.irsa["cloudwatch-read"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SendEmail"
        Effect   = "Allow"
        Action   = ["ses:SendEmail", "ses:SendRawEmail"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "s3_sync_ses" {
  name = "wind-irsa-s3-sync-ses"
  role = aws_iam_role.irsa["s3-sync"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # The backup-email paths (daily-report summary, delete-guard approval link,
        # per-share sync alerts) send via the SES v1 SendEmail API. v1 SendEmail's
        # resource-level support is limited (it evaluates both the sender AND, in the
        # sandbox, the verified-recipient identity, and an `identity/*` ARN wildcard
        # doesn't satisfy it) → use Resource:"*". Low risk for a backup-notification
        # role: it can only send mail (no escalation), and SES sandbox already limits
        # recipients to verified identities. SES SMTP senders (alertmanager/ai-advisor)
        # don't use this API. (Tighten if/when SES + senders are consolidated.)
        Sid      = "SendBackupEmails"
        Effect   = "Allow"
        Action   = ["ses:SendEmail", "ses:SendRawEmail"]
        Resource = "*"
      },
    ]
  })
}
