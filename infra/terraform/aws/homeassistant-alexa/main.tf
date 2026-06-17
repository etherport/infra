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

# This Lambda must be in us-east-1 for Alexa Smart Home skills
provider "aws" {
  region  = "us-east-1"
  profile = var.aws_profile != "" ? var.aws_profile : null
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Package Lambda code
data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda/handler.py"
  output_path = "${path.module}/lambda/handler.zip"
}

# Secrets Manager secret for Home Assistant access token
resource "aws_secretsmanager_secret" "ha_token" {
  name        = "homeassistant-alexa-token"
  description = "Long-lived access token for Home Assistant Alexa integration"
}

resource "aws_secretsmanager_secret_version" "ha_token" {
  secret_id = aws_secretsmanager_secret.ha_token.id
  secret_string = jsonencode({
    access_token = var.ha_access_token
  })
}

# Lambda function
resource "aws_lambda_function" "homeassistant_alexa" {
  filename         = data.archive_file.lambda.output_path
  function_name    = "homeassistant-alexa"
  description      = "Alexa Smart Home skill proxy for Home Assistant"
  role             = aws_iam_role.lambda.arn
  handler          = "handler.lambda_handler"
  source_code_hash = data.archive_file.lambda.output_base64sha256
  runtime          = "python3.13"
  architectures    = ["arm64"]
  memory_size      = 128
  timeout          = 10

  environment {
    variables = {
      BASE_URL                = var.ha_base_url
      SECRET_NAME             = aws_secretsmanager_secret.ha_token.name
      DEBUG                   = var.debug ? "True" : ""
      CF_ACCESS_CLIENT_ID     = var.cf_access_client_id
      CF_ACCESS_CLIENT_SECRET = var.cf_access_client_secret
    }
  }

  depends_on = [
    aws_iam_role_policy.secrets,
    aws_iam_role_policy.logs,
  ]
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/homeassistant-alexa"
  retention_in_days = 30
}

# Allow Alexa to invoke Lambda
resource "aws_lambda_permission" "alexa" {
  statement_id       = "AllowAlexaInvoke"
  action             = "lambda:InvokeFunction"
  function_name      = aws_lambda_function.homeassistant_alexa.function_name
  principal          = "alexa-connectedhome.amazon.com"
  event_source_token = var.alexa_skill_id
}
