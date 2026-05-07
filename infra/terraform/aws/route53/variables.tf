# Variables for route53 module

variable "aws_profile" {
  description = "AWS profile to use (empty string for environment variables in CI)"
  type        = string
  default     = "homelab"
}

variable "vpn_eip" {
  description = "Elastic IP address of the VPN server"
  type        = string
  default     = "44.240.60.80"
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
