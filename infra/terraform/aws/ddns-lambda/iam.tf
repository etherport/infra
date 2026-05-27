# IAM role for Lambda function
resource "aws_iam_role" "ddns_lambda" {
  name = "ddns-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# Route53 IAM policy removed 2026-05-27 — the Lambda no longer writes
# to Route53. CF DNS writes go over HTTPS using the cf_api_token in
# the Secrets Manager payload, no IAM-authenticated AWS calls needed.
# `aws_iam_role_policy.route53` is intentionally absent from this file
# so terraform plan removes the dangling resource on next apply.

# Policy for Secrets Manager access
resource "aws_iam_role_policy" "secrets" {
  name = "ddns-secrets-access"
  role = aws_iam_role.ddns_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = aws_secretsmanager_secret.api_key.arn
      }
    ]
  })
}

# Policy for CloudWatch Logs
resource "aws_iam_role_policy" "logs" {
  name = "ddns-cloudwatch-logs"
  role = aws_iam_role.ddns_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:*:log-group:/aws/lambda/ddns-updater:*"
      }
    ]
  })
}
