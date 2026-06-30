output "delivery_bucket" {
  value       = aws_s3_bucket.config.id
  description = "S3 bucket receiving AWS Config snapshots from both regions."
}

output "recorder_role_arn" {
  value       = aws_iam_role.recorder.arn
  description = "IAM role assumed by config.amazonaws.com."
}

output "aggregator_name" {
  value       = aws_config_configuration_aggregator.account.name
  description = "Pass to: aws configservice select-aggregate-resource-config --configuration-aggregator-name (used by cloud-tag-drift.yml)."
}
