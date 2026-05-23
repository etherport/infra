variable "aws_profile" {
  description = "AWS profile to use (empty string for environment variables in CI)"
  type        = string
  default     = "homelab"
}

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
  description = "DEPRECATED. Kept for backward compatibility with the previous single-SG variable. Use rule_specs instead."
  type        = string
  default     = "sg-08d12e417159c18d2"
}

variable "rule_specs" {
  description = "List of {security_group_id, port, protocols} tuples to manage. The Lambda keeps each SG's ingress rules for (port, protocols) in sync with the Route53 record IPs."
  type = list(object({
    security_group_id = string
    port              = number
    protocols         = list(string)
  }))
  default = [
    # dns_server SG: port 53 TCP+UDP (the original purpose).
    {
      security_group_id = "sg-08d12e417159c18d2"
      port              = 53
      protocols         = ["tcp", "udp"]
    },
    # FUTURE: allow_ssh SG (sg-0079fee23ee54417a), port 22 TCP. Gated
    # on confirming whether `86.98.93.115/32` (currently in the SG, UAE
    # IP, no description) should be preserved or is safe to drop on
    # the next Lambda run. Once confirmed, uncomment to enable Lambda
    # ownership of SSH ingress + remove the matching hardcoded TF
    # ingress rules in networking/security_groups.tf.
    # {
    #   security_group_id = "sg-0079fee23ee54417a"
    #   port              = 22
    #   protocols         = ["tcp"]
    # },
  ]
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
