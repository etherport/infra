# IAM role for Lambda
resource "aws_iam_role" "lambda" {
  name = "email-forward-lambda-role"

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

# S3 permissions for reading emails
resource "aws_iam_role_policy" "s3" {
  name = "email-forward-s3"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
        ]
        Resource = "${aws_s3_bucket.email.arn}/*"
      }
    ]
  })
}

# SES permissions for sending emails
resource "aws_iam_role_policy" "ses" {
  name = "email-forward-ses"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ses:SendRawEmail",
        ]
        Resource = "*"
      }
    ]
  })
}

# CloudWatch Logs permissions
resource "aws_iam_role_policy" "logs" {
  name = "email-forward-logs"
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
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/email-forward:*"
      }
    ]
  })
}
