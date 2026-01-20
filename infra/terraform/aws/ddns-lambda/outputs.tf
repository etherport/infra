output "api_endpoint" {
  description = "API Gateway endpoint URL for DDNS updates"
  value       = "${aws_apigatewayv2_api.ddns.api_endpoint}/update"
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret containing the API key"
  value       = aws_secretsmanager_secret.api_key.arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret"
  value       = aws_secretsmanager_secret.api_key.name
}

output "lambda_function_name" {
  description = "Name of the Lambda function"
  value       = aws_lambda_function.ddns.function_name
}

output "allowed_hostnames" {
  description = "Hostnames that can be updated via this endpoint"
  value       = var.allowed_hostnames
}

output "router_config_instructions" {
  description = "Instructions for configuring the Ubiquiti router"
  value       = <<-EOT
    Configure DDNS on your Ubiquiti router:

    Service: custom
    Server: ${replace(aws_apigatewayv2_api.ddns.api_endpoint, "https://", "")}/update
    Protocol: dyndns2
    Hostname: wan1.wind.etherport.net (or wan2.wind.etherport.net for second WAN)
    Username: unused
    Password: <retrieve from AWS Secrets Manager: ${aws_secretsmanager_secret.api_key.name}>

    To retrieve the API key:
      aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.api_key.name} --query SecretString --output text | jq -r .api_key
  EOT
}
