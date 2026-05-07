# Variables for networking module

variable "aws_profile" {
  description = "AWS profile to use (empty string for environment variables in CI)"
  type        = string
  default     = "homelab"
}

variable "ssh_allowed_ip" {
  description = "IP address allowed to SSH (CIDR notation)"
  type        = string
  default     = "47.159.189.230/32"
}
