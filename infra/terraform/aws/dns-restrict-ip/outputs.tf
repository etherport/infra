output "lambda_function_name" {
  description = "Name of the Lambda function"
  value       = aws_lambda_function.dns_restrict_ip.function_name
}

output "lambda_function_arn" {
  description = "ARN of the Lambda function"
  value       = aws_lambda_function.dns_restrict_ip.arn
}

output "security_group_id" {
  description = "Security group ID being managed"
  value       = var.security_group_id
}

output "monitored_records" {
  description = "DNS records being monitored for IP changes"
  value       = var.record_names
}

output "schedule" {
  description = "EventBridge schedule for the Lambda"
  value       = var.schedule_expression
}
