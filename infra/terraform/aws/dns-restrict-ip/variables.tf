variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "hosted_zone_id" {
  description = "Route53 hosted zone ID containing the DNS records"
  type        = string
  default     = "Z03500581XDWV5SKF5PK8"
}

variable "security_group_id" {
  description = "Security group ID to update with WAN IP rules"
  type        = string
  default     = "sg-08d12e417159c18d2"
}

variable "record_names" {
  description = "List of DNS record names to monitor for IP addresses"
  type        = list(string)
  default = [
    "wind.etherport.net",
    "wan1.wind.etherport.net",
    "wan2.wind.etherport.net"
  ]
}

variable "schedule_expression" {
  description = "EventBridge schedule expression for running the Lambda"
  type        = string
  default     = "rate(5 minutes)"
}

variable "lambda_memory" {
  description = "Lambda function memory in MB"
  type        = number
  default     = 128
}

variable "lambda_timeout" {
  description = "Lambda function timeout in seconds"
  type        = number
  default     = 30
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 30
}
