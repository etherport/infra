# External Monitoring for Homelab
# Uses Route53 health checks to monitor endpoints from AWS edge locations
# Sends alerts via SNS when endpoints become unhealthy

terraform {
  required_version = ">= 1.14"
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
    tags = var.tags
  }
}

# CloudWatch alarms must be in us-east-1 for Route53 health checks
provider "aws" {
  alias   = "us_east_1"
  region  = "us-east-1"
  profile = var.aws_profile != "" ? var.aws_profile : null

  default_tags {
    tags = var.tags
  }
}

# SNS Topic for alerts
resource "aws_sns_topic" "alerts" {
  provider = aws.us_east_1
  name     = "homelab-external-monitoring-alerts"
}

# Policy to allow CloudWatch alarms to publish to SNS
resource "aws_sns_topic_policy" "alerts" {
  provider = aws.us_east_1
  arn      = aws_sns_topic.alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudWatchAlarms"
        Effect = "Allow"
        Principal = {
          Service = "cloudwatch.amazonaws.com"
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.alerts.arn
        Condition = {
          ArnLike = {
            "aws:SourceArn" = "arn:aws:cloudwatch:us-east-1:830881980142:alarm:homelab-*"
          }
        }
      },
      {
        Sid    = "DefaultPolicy"
        Effect = "Allow"
        Principal = {
          AWS = "*"
        }
        Action = [
          "sns:GetTopicAttributes",
          "sns:SetTopicAttributes",
          "sns:AddPermission",
          "sns:RemovePermission",
          "sns:DeleteTopic",
          "sns:Subscribe",
          "sns:ListSubscriptionsByTopic",
          "sns:Publish"
        ]
        Resource = aws_sns_topic.alerts.arn
        Condition = {
          StringEquals = {
            "AWS:SourceOwner" = "830881980142"
          }
        }
      }
    ]
  })
}

resource "aws_sns_topic_subscription" "email" {
  provider  = aws.us_east_1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_sns_topic_subscription" "email_backup" {
  count     = var.alert_email_backup != "" ? 1 : 0
  provider  = aws.us_east_1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email_backup
}

# Route53 Health Checks
resource "aws_route53_health_check" "endpoint" {
  for_each = { for k, v in var.endpoints : k => v if v.enabled }

  fqdn              = each.value.fqdn
  port              = each.value.port
  type              = each.value.type
  resource_path     = each.value.type != "TCP" ? each.value.resource_path : null
  search_string     = each.value.search_string != "" ? each.value.search_string : null
  failure_threshold = each.value.failure_threshold
  request_interval  = each.value.request_interval

  # Check from multiple regions for reliability
  regions = ["us-west-2", "us-east-1", "eu-west-1"]

  tags = {
    Name = "homelab-${each.key}"
  }
}

# CloudWatch Alarms for each health check
resource "aws_cloudwatch_metric_alarm" "health_check" {
  provider = aws.us_east_1

  for_each = aws_route53_health_check.endpoint

  alarm_name          = "homelab-${each.key}-unhealthy"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HealthCheckStatus"
  namespace           = "AWS/Route53"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  alarm_description   = "Homelab endpoint ${each.key} is unhealthy"
  treat_missing_data  = "breaching"

  dimensions = {
    HealthCheckId = each.value.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# Composite health check - alerts if ANY endpoint is down
resource "aws_route53_health_check" "composite" {
  type = "CALCULATED"

  child_health_threshold = length(aws_route53_health_check.endpoint)
  child_healthchecks     = [for hc in aws_route53_health_check.endpoint : hc.id]

  tags = {
    Name = "homelab-composite-all-healthy"
  }
}

resource "aws_cloudwatch_metric_alarm" "composite" {
  provider = aws.us_east_1

  alarm_name          = "homelab-any-endpoint-unhealthy"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HealthCheckStatus"
  namespace           = "AWS/Route53"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  alarm_description   = "One or more homelab endpoints are unhealthy"
  treat_missing_data  = "breaching"

  dimensions = {
    HealthCheckId = aws_route53_health_check.composite.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# =============================================================================
# H46 dead-man's switch (2026-07-03). The in-cluster watchdog-deadman CronJob
# (platform/kubernetes/monitoring/14-watchdog-deadman.yaml) publishes
# Wind/Deadman:WatchdogSeen=1 every 5 min ONLY when the Prometheus Watchdog
# alert is actively firing in Alertmanager. If the cluster, Prometheus,
# Alertmanager, or the publisher dies -> the metric goes missing -> this alarm
# fires through AWS (CW->SNS->email), fully OUTSIDE the cluster's alert path.
# =============================================================================
resource "aws_cloudwatch_metric_alarm" "watchdog_deadman" {
  provider            = aws.us_east_1 # the alerts SNS topic lives here (R53 requirement); bonus: region-independent of the cluster
  alarm_name          = "wind-watchdog-deadman"
  alarm_description   = "The in-cluster alert pipeline heartbeat (Prometheus Watchdog -> Alertmanager -> CW) has gone SILENT. Prometheus/Alertmanager/the cluster/the publisher is down - in-cluster email alerts CANNOT be trusted right now. Check: kubectl -n monitoring get pods; the watchdog-deadman CronJob logs."
  namespace           = "Wind/Deadman"
  metric_name         = "WatchdogSeen"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}
