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
  profile = "homelab"
}

data "aws_caller_identity" "current" {}

# Package Lambda code
data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda/handler.py"
  output_path = "${path.module}/lambda/handler.zip"
}

# S3 bucket for email storage
resource "aws_s3_bucket" "email" {
  bucket = var.s3_bucket_name
}

resource "aws_s3_bucket_lifecycle_configuration" "email" {
  bucket = aws_s3_bucket.email.id

  rule {
    id     = "expire-old-emails"
    status = "Enabled"

    expiration {
      days = var.email_retention_days
    }

    filter {
      prefix = "emails/"
    }
  }
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
      VERIFIED_SENDER    = var.verified_sender
      GRAHAM_FORWARD_TO  = var.graham_forward_to
      MARK_FORWARD_TO    = var.mark_forward_to
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
  bucket = aws_s3_bucket.email.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.email_forward.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "emails/"
  }

  depends_on = [aws_lambda_permission.s3]
}

# Allow S3 to invoke Lambda
resource "aws_lambda_permission" "s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.email_forward.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.email.arn
  source_account = data.aws_caller_identity.current.account_id
}

# Allow SES to invoke Lambda (for receipt rules)
resource "aws_lambda_permission" "ses" {
  statement_id  = "AllowSESInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.email_forward.function_name
  principal     = "ses.amazonaws.com"
  source_arn    = "arn:aws:ses:${var.aws_region}:${data.aws_caller_identity.current.account_id}:receipt-rule-set/${var.ses_rule_set_name}:receipt-rule/${var.ses_receipt_rule_name}"
  source_account = data.aws_caller_identity.current.account_id
}
