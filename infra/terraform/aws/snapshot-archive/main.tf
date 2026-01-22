terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
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

# Lambda function
resource "aws_lambda_function" "snapshot_archive" {
  filename         = data.archive_file.lambda.output_path
  function_name    = "snapshot-archive"
  role             = aws_iam_role.lambda.arn
  handler          = "handler.lambda_handler"
  source_code_hash = data.archive_file.lambda.output_base64sha256
  runtime          = "python3.13"
  architectures    = ["arm64"]
  memory_size      = 128
  timeout          = 30

  environment {
    variables = {
      ARCHIVE_RETENTION_DAYS  = var.archive_retention_days
      ACTIVE_ARCHIVE_INTERVAL = var.active_archive_interval
      DLM_POLICY_ID           = var.dlm_policy_id
      SES_SENDER              = var.ses_sender
      SES_RECIPIENT           = var.ses_recipient
      SES_SUBJECT             = var.ses_subject
      SES_FROM_NAME           = var.ses_from_name
      SES_REPLY_TO            = var.ses_reply_to
      SES_REGION              = var.aws_region
    }
  }

  depends_on = [
    aws_iam_role_policy.ec2,
    aws_iam_role_policy.ses,
    aws_iam_role_policy.logs,
  ]
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/snapshot-archive"
  retention_in_days = 30
}

# EventBridge scheduled rule
resource "aws_cloudwatch_event_rule" "schedule" {
  name                = "snapshot-archive-daily"
  description         = "Trigger snapshot-archive Lambda daily at 1 PM UTC"
  schedule_expression = var.schedule_expression
  state               = "ENABLED"
}

resource "aws_cloudwatch_event_target" "lambda" {
  rule      = aws_cloudwatch_event_rule.schedule.name
  target_id = "snapshot-archive-lambda"
  arn       = aws_lambda_function.snapshot_archive.arn
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.snapshot_archive.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.schedule.arn
}
