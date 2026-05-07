terraform {
  required_version = ">= 1.0"

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
      MARK_FORWARD_TO   = var.mark_forward_to
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

# Allow SES to invoke Lambda (for receipt rules)
resource "aws_lambda_permission" "ses_graham" {
  statement_id   = "AllowSESInvokeGraham"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.email_forward.function_name
  principal      = "ses.amazonaws.com"
  source_arn     = aws_ses_receipt_rule.fwd_graham.arn
  source_account = data.aws_caller_identity.current.account_id
}

resource "aws_lambda_permission" "ses_mark" {
  statement_id   = "AllowSESInvokeMark"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.email_forward.function_name
  principal      = "ses.amazonaws.com"
  source_arn     = aws_ses_receipt_rule.fwd_mark.arn
  source_account = data.aws_caller_identity.current.account_id
}

# =============================================================================
# SES Domain Identities
# =============================================================================

resource "aws_ses_domain_identity" "etherport" {
  domain = "etherport.net"
}

resource "aws_ses_domain_identity" "grahamsmith" {
  domain = "grahamsmith.net"
}

resource "aws_ses_domain_identity" "stopthecastle" {
  domain = "stopthecastle.com"
}

resource "aws_ses_domain_identity" "smithforsb" {
  domain = "smithforsb.com"
}

# =============================================================================
# SES Email Identities
# =============================================================================

resource "aws_ses_email_identity" "g_grahamsmith" {
  email = "g@grahamsmith.net"
}

resource "aws_ses_email_identity" "grahamsm_gmail" {
  email = "grahamsm@gmail.com"
}

resource "aws_ses_email_identity" "mgoodwin_gmail" {
  email = "mgoodwin.us@gmail.com"
}

resource "aws_ses_email_identity" "graham_icloud" {
  email = "graham.m.smith@me.com"
}

# =============================================================================
# SES Receipt Rule Set
# =============================================================================

resource "aws_ses_receipt_rule_set" "inbound" {
  rule_set_name = "INBOUND_MAIL"
}

resource "aws_ses_active_receipt_rule_set" "main" {
  rule_set_name = aws_ses_receipt_rule_set.inbound.rule_set_name
}

# =============================================================================
# SES Receipt Rules
# =============================================================================

resource "aws_ses_receipt_rule" "fwd_graham" {
  name          = "fwd_graham"
  rule_set_name = aws_ses_receipt_rule_set.inbound.rule_set_name
  enabled       = true
  scan_enabled  = true

  recipients = [
    "g@grahamsmith.net",
    "graham@grahamsmith.net",
    "graham@smithforsb.com",
    "info@smithforsb.com",
    "me@grahamsmith.net",
    "windtryst@grahamsmith.net",
    "workroom@grahamsmith.net",
  ]

  s3_action {
    bucket_name       = data.aws_s3_bucket.email.id
    object_key_prefix = "emails/graham/"
    iam_role_arn      = aws_iam_role.ses_s3_graham.arn
    position          = 1
  }
}

resource "aws_ses_receipt_rule" "fwd_mark" {
  name          = "fwd_mark"
  rule_set_name = aws_ses_receipt_rule_set.inbound.rule_set_name
  enabled       = true
  scan_enabled  = true

  recipients = [
    "info@stopthecastle.com",
    "mark@smithforsb.com",
  ]

  s3_action {
    bucket_name       = data.aws_s3_bucket.email.id
    object_key_prefix = "emails/mark/"
    iam_role_arn      = aws_iam_role.ses_s3_mark.arn
    position          = 1
  }
}
