# Variables for route53 module

variable "aws_profile" {
  description = "AWS profile to use (empty string for environment variables in CI)"
  type        = string
  default     = "homelab"
}

variable "alb_dns_name" {
  description = "DNS name of the private-infra ALB"
  type        = string
  default     = "dualstack.private-infra-alb-687735217.us-west-2.elb.amazonaws.com"
}

variable "alb_zone_id" {
  description = "Route53 zone ID of the private-infra ALB"
  type        = string
  default     = "Z1H1FL5HABSF5"
}

variable "vpn_usw2_public_ip" {
  description = "Public IP (EIP) of the VPN instance in us-west-2 (Oregon)"
  type        = string
  default     = "44.240.60.80"
}

variable "vpn_use1_public_ip" {
  description = "Public IP (EIP) of the VPN instance in us-east-1 (Virginia)"
  type        = string
  default     = "35.169.37.16"
}
