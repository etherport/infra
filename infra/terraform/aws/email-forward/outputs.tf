output "lambda_function_arn" {
  description = "ARN of the Lambda function"
  value       = aws_lambda_function.email_forward.arn
}

output "lambda_function_name" {
  description = "Name of the Lambda function"
  value       = aws_lambda_function.email_forward.function_name
}

output "s3_bucket_name" {
  description = "Name of the S3 bucket for email storage"
  value       = data.aws_s3_bucket.email.id
}

output "s3_bucket_arn" {
  description = "ARN of the S3 bucket"
  value       = data.aws_s3_bucket.email.arn
}

output "ses_rule_set_name" {
  description = "Name of the SES receipt rule set"
  value       = aws_ses_receipt_rule_set.inbound.rule_set_name
}
