# IAM role for Lambda
resource "aws_iam_role" "lambda" {
  name = "snapshot-archive-lambda-role"

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

# EC2 permissions for snapshot management
resource "aws_iam_role_policy" "ec2" {
  name = "snapshot-archive-ec2"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeVolumes",
          "ec2:DescribeSnapshots",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:ModifySnapshotTier",
          "ec2:DeleteSnapshot",
          "ec2:CreateTags",
        ]
        Resource = "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:snapshot/*"
      }
    ]
  })
}

# SES permissions for sending emails
resource "aws_iam_role_policy" "ses" {
  name = "snapshot-archive-ses"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ses:SendEmail",
        ]
        Resource = [
          "arn:aws:ses:${var.aws_region}:${data.aws_caller_identity.current.account_id}:identity/${var.ses_sender}",
          "arn:aws:ses:${var.aws_region}:${data.aws_caller_identity.current.account_id}:identity/${split("@", var.ses_sender)[1]}",
        ]
      }
    ]
  })
}

# CloudWatch Logs permissions
resource "aws_iam_role_policy" "logs" {
  name = "snapshot-archive-logs"
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
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/snapshot-archive:*"
      }
    ]
  })
}
