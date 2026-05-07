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

variable "hosted_zone_id" {
  description = "Route53 hosted zone ID for etherport.net"
  type        = string
  default     = "Z03500581XDWV5SKF5PK8"
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
