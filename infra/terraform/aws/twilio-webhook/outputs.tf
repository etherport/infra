output "function_url" {
  description = "Public webhook URL — point Twilio DID voice_url + sms_url at this."
  value       = aws_lambda_function_url.twilio_webhook.function_url
}

output "function_arn" {
  description = "Lambda function ARN (for cross-module references)."
  value       = aws_lambda_function.twilio_webhook.arn
}

output "function_name" {
  description = "Lambda function name (for CloudWatch / CLI invocation)."
  value       = aws_lambda_function.twilio_webhook.function_name
}
