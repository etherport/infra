# AWS monthly cost budget — alerts when projected/actual spend nears
# the configured threshold. Reuses the SNS alerts topic so notifications
# follow the same email pipeline as the Route53 health-check alarms.

resource "aws_budgets_budget" "monthly" {
  name              = "homelab-monthly"
  budget_type       = "COST"
  limit_amount      = var.monthly_budget_usd
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2026-01-01_00:00"

  # Forecast: notify when AWS predicts month-end spend will exceed 100%.
  # Fires early in the cycle if a runaway resource was created.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email, var.alert_email_backup]
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
  }

  # Soft warning: actual spend crossed 80% of budget.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email, var.alert_email_backup]
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
  }

  # Hard breach: actual spend hit 100% of budget.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email, var.alert_email_backup]
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
  }
}
