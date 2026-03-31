# External Monitoring for Homelab
# Uses Route53 health checks to monitor endpoints from AWS edge locations
# Sends alerts via SNS when endpoints become unhealthy

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = "homelab"

  default_tags {
    tags = var.tags
  }
}

# CloudWatch alarms must be in us-east-1 for Route53 health checks
provider "aws" {
  alias   = "us_east_1"
  region  = "us-east-1"
  profile = "homelab"

  default_tags {
    tags = var.tags
  }
}

# SNS Topic for alerts
resource "aws_sns_topic" "alerts" {
  provider = aws.us_east_1
  name     = "homelab-external-monitoring-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  provider  = aws.us_east_1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
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
