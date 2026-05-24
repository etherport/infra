// AI Advisor read-only IAM user (M45 Phase B).
//
// Creates a dedicated IAM user the in-cluster advisor controller
// (platform/kubernetes/auto-remediation/) uses to fetch CloudWatch
// Logs context when diagnosing alerts about AWS-side resources
// (Lambda, EC2 cloudwatch agent, etc.).
//
// Scope is tight: read-only on CloudWatch Logs only. No write, no
// other AWS service access. The advisor never executes anything on
// AWS — it only reads logs to feed into Claude's prompt.
//
// After `terraform apply`:
//   1. Capture the outputs (terraform output -raw access_key_id
//      and terraform output -raw access_key_secret).
//   2. Put them into the SOPS secret at
//      platform/kubernetes/auto-remediation/aws-cloudwatch-creds.sops.yaml
//      via `sops <file>` (placeholder is committed).
//   3. Commit + push. Flux applies; controller pod picks them up
//      on its next roll.

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile != "" ? var.aws_profile : null

  default_tags {
    tags = {
      ManagedBy = "terraform"
      Module    = "ai-advisor-iam"
      Purpose   = "ai-advisor-cloudwatch-read"
    }
  }
}

variable "aws_profile" {
  description = "AWS profile (empty string for env vars in CI)"
  type        = string
  default     = "homelab"
}

variable "aws_region" {
  description = "AWS region (only matters for IAM, which is global, but the provider needs one)"
  type        = string
  default     = "us-west-2"
}

resource "aws_iam_user" "ai_advisor" {
  name = "ai-advisor-readonly"
  path = "/services/"
  tags = {
    Purpose = "ai-advisor-cloudwatch-logs-read"
  }
}

resource "aws_iam_user_policy" "ai_advisor_cw_logs" {
  name = "ai-advisor-cloudwatch-logs-read"
  user = aws_iam_user.ai_advisor.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        // Discover log groups (filtered by Lambda + EC2 naming
        // patterns the advisor knows to look for).
        Sid    = "DescribeLogGroups"
        Effect = "Allow"
        Action = [
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
        ]
        Resource = "*"
      },
      {
        // Read events from log groups under known prefixes. Lambda
        // groups are /aws/lambda/<name>; EC2 CloudWatch agent groups
        // are typically /aws/ec2/<instance-id> or a custom name set
        // in the agent config.
        Sid    = "ReadLogs"
        Effect = "Allow"
        Action = [
          "logs:GetLogEvents",
          "logs:FilterLogEvents",
          "logs:StartQuery",
          "logs:GetQueryResults",
        ]
        // Lambda + EC2-agent log groups only. Tighten further if a
        // new naming pattern lands.
        Resource = [
          "arn:aws:logs:*:*:log-group:/aws/lambda/*",
          "arn:aws:logs:*:*:log-group:/aws/lambda/*:log-stream:*",
          "arn:aws:logs:*:*:log-group:/aws/ec2/*",
          "arn:aws:logs:*:*:log-group:/aws/ec2/*:log-stream:*",
          "arn:aws:logs:*:*:log-group:CloudWatchAgent*",
          "arn:aws:logs:*:*:log-group:CloudWatchAgent*:log-stream:*",
        ]
      },
    ]
  })
}

resource "aws_iam_access_key" "ai_advisor" {
  user = aws_iam_user.ai_advisor.name
}

output "access_key_id" {
  description = "Access key ID for the ai-advisor-readonly user"
  value       = aws_iam_access_key.ai_advisor.id
}

output "access_key_secret" {
  description = "Access key secret for the ai-advisor-readonly user"
  value       = aws_iam_access_key.ai_advisor.secret
  sensitive   = true
}

output "iam_user_arn" {
  value = aws_iam_user.ai_advisor.arn
}
