variable "aws_profile" {
  description = "AWS profile to use (empty string for environment variables in CI)"
  type        = string
  default     = "homelab"
}

variable "aws_region" {
  description = "AWS region for Lambda and API Gateway"
  type        = string
  default     = "us-west-2"
}

variable "cf_zone_id" {
  description = <<-EOT
    Cloudflare zone ID for etherport.net. The Lambda makes
    https://api.cloudflare.com/client/v4/zones/<id>/dns_records calls
    against this zone using the cf_api_token stored in Secrets Manager.

    Migrated 2026-05-27 from `hosted_zone_id` (Route53). The original
    Route53 zone was deleted as part of the broader DNS-to-CF migration.
  EOT
  type        = string
  default     = "c45213cbf36fc634b6b75ae9abd49c59"
}

variable "allowed_hostnames" {
  description = "List of hostnames the Lambda is allowed to update"
  type        = list(string)
  default     = ["wan1.wind.etherport.net", "wan2.wind.etherport.net"]
}

variable "ttl" {
  description = "TTL for DNS records in seconds"
  type        = number
  default     = 300
}

variable "lambda_memory" {
  description = "Lambda function memory in MB"
  type        = number
  default     = 128
}

variable "lambda_timeout" {
  description = "Lambda function timeout in seconds"
  type        = number
  default     = 10
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 30
}
