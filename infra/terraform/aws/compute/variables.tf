# Variables for compute module

variable "aws_profile" {
  description = "AWS profile to use (empty string for environment variables in CI)"
  type        = string
  default     = "homelab"
}

variable "gs_ec2_public_key" {
  description = "Public key for GS-EC2 key pair"
  type        = string
  sensitive   = true
  # This will be populated during import - key pairs don't expose public key after creation
  # Set to empty string for import, actual key not needed for existing resources
  default = ""
}

variable "alert_email" {
  description = "Email address for CloudWatch alarm notifications"
  type        = string
  default     = "graham.m.smith@me.com"
}
