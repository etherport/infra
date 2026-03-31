# External Monitoring Outputs

output "health_check_ids" {
  description = "Map of endpoint names to Route53 health check IDs"
  value       = { for k, v in aws_route53_health_check.endpoint : k => v.id }
}

output "sns_topic_arn" {
  description = "SNS topic ARN for alerts"
  value       = aws_sns_topic.alerts.arn
}

output "composite_health_check_id" {
  description = "Composite health check ID (all endpoints)"
  value       = aws_route53_health_check.composite.id
}

output "monitoring_dashboard_url" {
  description = "URL to Route53 health checks in AWS Console"
  value       = "https://console.aws.amazon.com/route53/healthchecks/home"
}
