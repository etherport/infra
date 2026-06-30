# Variables for the config stack.

variable "aws_profile" {
  description = "AWS profile to use (empty string for environment-variable creds in CI)"
  type        = string
  default     = "homelab"
}
