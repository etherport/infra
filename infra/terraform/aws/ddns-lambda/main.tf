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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
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
      Module      = "ddns-lambda"
    }
  }
}

# -----------------------------------------------------------------------------
# Secrets Manager - API Key
# -----------------------------------------------------------------------------

# Generate a random API key
resource "random_password" "api_key" {
  length  = 32
  special = false
}

# Store API key in Secrets Manager
resource "aws_secretsmanager_secret" "api_key" {
  name                    = "ddns-api-key"
  description             = "API key for DDNS Lambda endpoint"
  recovery_window_in_days = 0 # Allow immediate deletion for development
}

resource "aws_secretsmanager_secret_version" "api_key" {
  secret_id = aws_secretsmanager_secret.api_key.id
  secret_string = jsonencode({
    api_key = random_password.api_key.result
  })
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
resource "aws_lambda_function" "ddns" {
  function_name    = "ddns-updater"
  description      = "DDNS endpoint for Ubiquiti router to update Route53"
  role             = aws_iam_role.ddns_lambda.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  memory_size      = var.lambda_memory
  timeout          = var.lambda_timeout
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  environment {
    variables = {
      CF_ZONE_ID        = var.cf_zone_id
      ALLOWED_HOSTNAMES = join(",", var.allowed_hostnames)
      SECRET_ARN        = aws_secretsmanager_secret.api_key.arn
      TTL               = tostring(var.ttl)
    }
  }

  # route53 IAM policy removed 2026-05-27 alongside the CF migration —
  # the Lambda now makes CF API calls over HTTPS, no Route53 IAM needed.
  depends_on = [
    aws_iam_role_policy.secrets,
    aws_iam_role_policy.logs,
  ]
}

# CloudWatch Log Group for Lambda
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${aws_lambda_function.ddns.function_name}"
  retention_in_days = var.log_retention_days
}

# -----------------------------------------------------------------------------
# API Gateway (HTTP API)
# -----------------------------------------------------------------------------

# HTTP API
resource "aws_apigatewayv2_api" "ddns" {
  name          = "ddns-api"
  description   = "DDNS endpoint for Ubiquiti router"
  protocol_type = "HTTP"
}

# Lambda integration
resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.ddns.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.ddns.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

# Route for /update
resource "aws_apigatewayv2_route" "update" {
  api_id    = aws_apigatewayv2_api.ddns.id
  route_key = "GET /update"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

# Default stage with auto-deploy
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.ddns.id
  name        = "$default"
  auto_deploy = true

  # Note: Access logging disabled to simplify IAM permissions
  # Lambda function logs provide sufficient visibility
}

# CloudWatch Log Group for API Gateway
resource "aws_cloudwatch_log_group" "api_gateway" {
  name              = "/aws/apigateway/ddns-api"
  retention_in_days = var.log_retention_days
}

# Permission for API Gateway to invoke Lambda
resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ddns.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.ddns.execution_arn}/*/*"
}
