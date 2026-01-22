output "lambda_function_arn" {
  description = "ARN of the Lambda function"
  value       = aws_lambda_function.snapshot_archive.arn
}

output "lambda_function_name" {
  description = "Name of the Lambda function"
  value       = aws_lambda_function.snapshot_archive.function_name
}

output "eventbridge_rule_arn" {
  description = "ARN of the EventBridge schedule rule"
  value       = aws_cloudwatch_event_rule.schedule.arn
}

output "schedule" {
  description = "Schedule expression for the Lambda trigger"
  value       = var.schedule_expression
}
