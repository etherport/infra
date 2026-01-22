output "lambda_function_arn" {
  description = "ARN of the Lambda function"
  value       = aws_lambda_function.homeassistant_alexa.arn
}

output "lambda_function_name" {
  description = "Name of the Lambda function"
  value       = aws_lambda_function.homeassistant_alexa.function_name
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret"
  value       = aws_secretsmanager_secret.ha_token.arn
}
