# IAM role for Lambda
resource "aws_iam_role" "lambda" {
  name = "homeassistant-alexa-lambda-role"

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

# Secrets Manager permissions
resource "aws_iam_role_policy" "secrets" {
  name = "homeassistant-alexa-secrets"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
        ]
        Resource = aws_secretsmanager_secret.ha_token.arn
      }
    ]
  })
}

# CloudWatch Logs permissions
resource "aws_iam_role_policy" "logs" {
  name = "homeassistant-alexa-logs"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/homeassistant-alexa:*"
      }
    ]
  })
}
