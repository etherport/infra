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

# -----------------------------------------------------------------------------
# Lambda Function
# -----------------------------------------------------------------------------

# Package the Lambda code
data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda/handler.py"
  output_path = "${path.module}/lambda/handler.zip"
}

# Lambda function
resource "aws_lambda_function" "dns_restrict_ip" {
  function_name    = "dns-restrict-ip"
  description      = "Syncs security group rules with Route53 DNS records for homelab WAN IPs"
  role             = aws_iam_role.lambda.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  memory_size      = var.lambda_memory
  timeout          = var.lambda_timeout
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  environment {
    variables = {
      HOSTED_ZONE_ID    = var.hosted_zone_id
      SECURITY_GROUP_ID = var.security_group_id
      RECORD_NAMES      = join(",", var.record_names)
    }
  }

  depends_on = [
    aws_iam_role_policy.route53,
    aws_iam_role_policy.ec2,
    aws_iam_role_policy.logs,
  ]
}

# CloudWatch Log Group for Lambda
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${aws_lambda_function.dns_restrict_ip.function_name}"
  retention_in_days = var.log_retention_days
}

# -----------------------------------------------------------------------------
# EventBridge Schedule (runs every 5 minutes)
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "schedule" {
  name                = "dns-restrict-ip-schedule"
  description         = "Trigger dns-restrict-ip Lambda every 5 minutes"
  schedule_expression = var.schedule_expression
}

resource "aws_cloudwatch_event_target" "lambda" {
  rule      = aws_cloudwatch_event_rule.schedule.name
  target_id = "dns-restrict-ip-lambda"
  arn       = aws_lambda_function.dns_restrict_ip.arn
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dns_restrict_ip.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.schedule.arn
}
