// GitHub Actions OIDC federation for AWS (H29).
//
// Replaces the long-lived static AWS keys (AWS_ACCESS_KEY_ID / _SECRET) in 22
// CI workflows with short-lived, per-run credentials minted via
// AssumeRoleWithWebIdentity. Trust is locked to THIS repo (main + pull_request).
//
// BOOTSTRAP: this stack creates an IAM OIDC provider + role + policy, which needs
// admin IAM perms — claude-admin (PowerUser, no iam:*) CANNOT apply it. Run the
// FIRST apply with admin creds (gs_admin). After that, CI assumes the role and the
// stack self-manages. See infra/terraform/aws/github-oidc/README.md.

terraform {
  required_version = ">= 1.5"
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
  account_id = "830881980142"
  repo       = "sparked-diamond/infra"
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

# Trust policy: only GitHub Actions for THIS repo, on main or any pull_request.
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
        "repo:${local.repo}:pull_request",
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
