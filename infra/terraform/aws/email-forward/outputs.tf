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
  value       = aws_s3_bucket.email.id
}

output "s3_bucket_arn" {
  description = "ARN of the S3 bucket"
  value       = aws_s3_bucket.email.arn
}
