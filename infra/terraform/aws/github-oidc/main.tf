// GitHub Actions OIDC federation for AWS (H29).
//
// Replaces the long-lived static AWS keys (AWS_ACCESS_KEY_ID / _SECRET) in CI
// workflows with short-lived, per-run credentials minted via
// AssumeRoleWithWebIdentity.
//
// Two repos federate through the single account-level OIDC provider below, each
// with its own role whose trust is locked to that repo (main + pull_request):
//   - sparked-diamond/infra         -> role gh-actions-terraform   (H29)
//   - sparked-diamond/personal-web  -> role gh-actions-personal-web
//
// BOOTSTRAP: this stack creates an IAM OIDC provider + role + policy, which needs
// admin IAM perms — claude-admin (PowerUser, no iam:*) CANNOT apply it. Run the
// FIRST apply with admin creds (gs_admin). After that, CI assumes the role and the
// stack self-manages. See infra/terraform/aws/github-oidc/README.md.

terraform {
  required_version = ">= 1.14"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile != "" ? var.aws_profile : null

  default_tags {
    tags = {
      ManagedBy = "terraform"
      Module    = "github-oidc"
      Purpose   = "github-actions-oidc-federation"
    }
  }
}

locals {
  account_id        = "830881980142"
  repo              = "sparked-diamond/infra"
  repo_personal_web = "sparked-diamond/personal-web"
  # Org migration (2026-08): repos move sparked-diamond (user) -> etherport (org).
  # The OIDC `sub` claim embeds the repo path, so the trust must accept BOTH during
  # the cutover (CI keeps AWS across the transfer). Drop the *_old paths after the
  # move is verified. See docs/planning/github-org-migration-2026-08.md.
  repo_new              = "etherport/infra"
  repo_personal_web_new = "etherport/personal-web"
}

# GitHub's OIDC identity provider. One per account. If it already exists,
# `terraform import aws_iam_openid_connect_provider.github <arn>` before apply.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS validates token.actions.githubusercontent.com against its own trust store,
  # so the thumbprint is no longer security-relevant for this well-known IdP — but
  # the argument is still accepted. GitHub's published root thumbprints:
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

# Trust policy: only GitHub Actions for THIS repo, on MAIN ONLY (M140,
# 2026-07-11): `pull_request` moved to the read-only PLAN role below — a
# PR-authored branch must never hold a PowerUser session during "plan".
data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${local.repo}:ref:refs/heads/main",
        "repo:${local.repo_new}:ref:refs/heads/main",
      ]
    }
  }
}

resource "aws_iam_role" "gh_actions_terraform" {
  name                 = "gh-actions-terraform"
  description          = "Assumed by GitHub Actions (OIDC) to run Terraform. Replaces static CI keys (H29)."
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
}

# Scoped IAM/OIDC write surface (PowerUserAccess below covers everything else CI's
# terraform touches: EC2/S3/Lambda/SES/secretsmanager/dynamodb/etc.).
resource "aws_iam_policy" "gh_actions_terraform_iam" {
  name        = "gh-actions-terraform-iam"
  description = "IAM/OIDC management surface for the gh-actions-terraform CI role (H29). Anti-escalation Deny on attaching admin policies."
  policy      = file("${path.module}/../iam-policies/gh-actions-terraform-iam.json")
}

resource "aws_iam_role_policy_attachment" "poweruser" {
  role       = aws_iam_role.gh_actions_terraform.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

resource "aws_iam_role_policy_attachment" "iam" {
  role       = aws_iam_role.gh_actions_terraform.name
  policy_arn = aws_iam_policy.gh_actions_terraform_iam.arn
}

# ---------------------------------------------------------------------------
# M140 (2026-07-11): read-only PLAN role for pull_request-triggered runs.
# PR plans execute PR-authored HCL (data sources, `external` provider) — under
# the old single-role model that ran with PowerUserAccess. This role mirrors
# the M71 Roles-Anywhere plan/debug scope: broad READ (ReadOnlyAccess) for
# plan refresh, tfstate read + lockfile-only writes, and Denies on the
# high-value exfiltration paths (backup-bucket object data, Secrets Manager,
# SSM SecureString, KMS decrypt). No stack uses aws_secretsmanager/aws_ssm
# data sources (verified 2026-07-11), so the Deny can't break a legit plan.
# ⚠️ RESIDUAL (same as M71): plan needs the state, and TF state stores
# PLAINTEXT secrets — a malicious PR can still read state-resident secrets.
# That is an inherent cost of "can run plan"; the win is no WRITE capability
# and no Secrets-Manager/backup-data reach.
# ---------------------------------------------------------------------------

locals {
  tfstate_bucket = "terraform.wind.etherport.net"
}

data "aws_iam_policy_document" "trust_plan" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.repo}:pull_request", "repo:${local.repo_new}:pull_request"]
    }
  }
}

resource "aws_iam_role" "gh_actions_terraform_plan" {
  name                 = "gh-actions-terraform-plan"
  description          = "Read-only terraform PLAN role for pull_request-triggered CI (M140). PowerUser stays on the main/dispatch role."
  assume_role_policy   = data.aws_iam_policy_document.trust_plan.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.gh_actions_terraform_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "plan_tfstate" {
  # State read everywhere in the bucket (plan needs the current state).
  statement {
    sid       = "TfStateRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${local.tfstate_bucket}/*"]
  }
  # S3-native locking (use_lockfile): plan takes the lock (Put) and releases
  # it (Delete) — scoped to `*.tflock` ONLY, so a PR plan can never write or
  # delete actual state objects.
  statement {
    sid       = "TfStateLockRW"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${local.tfstate_bucket}/*.tflock"]
  }
  statement {
    sid       = "TfStateList"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = ["arn:aws:s3:::${local.tfstate_bucket}"]
  }
  # Deny object-DATA reads outside the state bucket (incl. the versioned
  # backup buckets' s3:GetObjectVersion bypass). Enumerated actions, not
  # s3:Get*, so bucket-config reads (GetBucketPolicy/Versioning/…) that plan
  # refresh needs keep working. (Deny beats the ReadOnlyAccess Allow.)
  statement {
    sid           = "DenyObjectDataReads"
    effect        = "Deny"
    actions       = ["s3:GetObject", "s3:GetObjectVersion", "s3:GetObjectTorrent", "s3:GetObjectVersionTorrent"]
    not_resources = ["arn:aws:s3:::${local.tfstate_bucket}/*"]
  }
  # Secret / parameter / KMS reads — flat Deny (mirrors M71's RA scope).
  statement {
    sid    = "DenySecretAndKmsDecrypt"
    effect = "Deny"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:BatchGetSecretValue",
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
      "kms:Decrypt",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "plan_tfstate" {
  name   = "tfstate-plan-and-deny-data-reads"
  role   = aws_iam_role.gh_actions_terraform_plan.id
  policy = data.aws_iam_policy_document.plan_tfstate.json
}

# ---------------------------------------------------------------------------
# personal-web repo (sparked-diamond/personal-web) — CF DNS + SES + static
# sites. Same federation, separate role + trust so a leaked/compromised run in
# one repo can't assume the other's role.
# ---------------------------------------------------------------------------

# Trust policy: only GitHub Actions for the personal-web repo, main or any PR.
data "aws_iam_policy_document" "trust_personal_web" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${local.repo_personal_web}:ref:refs/heads/main",
        "repo:${local.repo_personal_web}:pull_request",
        "repo:${local.repo_personal_web_new}:ref:refs/heads/main",
        "repo:${local.repo_personal_web_new}:pull_request",
      ]
    }
  }
}

resource "aws_iam_role" "gh_actions_personal_web" {
  name                 = "gh-actions-personal-web"
  description          = "Assumed by GitHub Actions (OIDC) for the personal-web repo's Terraform. Replaces static CI keys."
  assume_role_policy   = data.aws_iam_policy_document.trust_personal_web.json
  max_session_duration = 3600
}

# PowerUserAccess covers everything personal-web's terraform touches except IAM:
# S3, CloudFront, ACM, SES, lambda:AddPermission, Route53 + Route53 Domains DNSSEC.
# The one IAM resource it manages (ses_put_s3_role) gets a narrowly scoped policy.
resource "aws_iam_policy" "gh_actions_personal_web_iam" {
  name        = "gh-actions-personal-web-iam"
  description = "Narrow IAM surface for the personal-web CI role: manage only ses_put_s3_role. Anti-escalation Deny on attaching admin policies."
  policy      = file("${path.module}/../iam-policies/gh-actions-personal-web-iam.json")
}

resource "aws_iam_role_policy_attachment" "personal_web_poweruser" {
  role       = aws_iam_role.gh_actions_personal_web.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

resource "aws_iam_role_policy_attachment" "personal_web_iam" {
  role       = aws_iam_role.gh_actions_personal_web.name
  policy_arn = aws_iam_policy.gh_actions_personal_web_iam.arn
}
