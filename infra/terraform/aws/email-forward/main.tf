terraform {
  required_version = ">= 1.14"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile != "" ? var.aws_profile : null

  default_tags {
    tags = {
      Environment = "homelab"
      ManagedBy   = "terraform"
      Module      = "email-forward"
    }
  }
}

data "aws_caller_identity" "current" {}

# Package Lambda code
data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda/handler.py"
  output_path = "${path.module}/lambda/handler.zip"
}

# S3 bucket for email storage (managed by s3 module)
data "aws_s3_bucket" "email" {
  bucket = var.s3_bucket_name
}

# Lambda function
resource "aws_lambda_function" "email_forward" {
  filename         = data.archive_file.lambda.output_path
  function_name    = "email-forward"
  description      = "Forwards incoming SES emails from S3 to personal addresses"
  role             = aws_iam_role.lambda.arn
  handler          = "handler.lambda_handler"
  source_code_hash = data.archive_file.lambda.output_base64sha256
  runtime          = "python3.13"
  architectures    = ["arm64"]
  memory_size      = 128
  timeout          = 10

  environment {
    variables = {
      VERIFIED_SENDER   = var.verified_sender
      GRAHAM_FORWARD_TO = var.graham_forward_to
    }
  }

  depends_on = [
    aws_iam_role_policy.s3,
    aws_iam_role_policy.ses,
    aws_iam_role_policy.logs,
  ]
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/email-forward"
  retention_in_days = 30
}

# S3 bucket notification to trigger Lambda
resource "aws_s3_bucket_notification" "email" {
  bucket = data.aws_s3_bucket.email.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.email_forward.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "emails/"
  }

  depends_on = [aws_lambda_permission.s3]
}

# Allow S3 to invoke Lambda
resource "aws_lambda_permission" "s3" {
  statement_id   = "AllowS3Invoke"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.email_forward.function_name
  principal      = "s3.amazonaws.com"
  source_arn     = data.aws_s3_bucket.email.arn
  source_account = data.aws_caller_identity.current.account_id
}

# =============================================================================
# SES Domain Identities — etherport.net stays here; the 3 personal
# domains (grahamsmith.net, smithforsb.com, stopthecastle.com) moved
# to the personal-web repo on 2026-05-27 (terraform/ses-email-forward).
# =============================================================================

resource "aws_ses_domain_identity" "etherport" {
  domain = "etherport.net"
}

# =============================================================================
# SES Email Identities — homelab-owned forward TARGET addresses. The
# verified sender g@grahamsmith.net moved to personal-web with the
# rest of the personal-domain bits.
# =============================================================================

resource "aws_ses_email_identity" "grahamsm_gmail" {
  email = "grahamsm@gmail.com"
}

resource "aws_ses_email_identity" "graham_icloud" {
  email = "graham.m.smith@me.com"
}

# =============================================================================
# SES Receipt Rule Set — singleton at the AWS account level; homelab
# is the canonical owner. Individual receipt rules attached to this
# set can live in either repo (e.g., the personal-web ses-email-forward
# module owns `fwd_graham` for personal-domain inbound).
# =============================================================================

resource "aws_ses_receipt_rule_set" "inbound" {
  rule_set_name = "INBOUND_MAIL"
}

resource "aws_ses_active_receipt_rule_set" "main" {
  rule_set_name = aws_ses_receipt_rule_set.inbound.rule_set_name
}

