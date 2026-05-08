# AWS US-East-1 Hub Infrastructure
# Variables

variable "aws_profile" {
  description = "AWS profile to use (empty string for environment variables in CI)"
  type        = string
  default     = "homelab"
}

#------------------------------------------------------------------------------
# Network Configuration
#------------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the us-east-1 VPC"
  type        = string
  default     = "10.10.104.0/22"
}

variable "hub_vpc_id" {
  description = "VPC ID of the us-west-2 hub"
  type        = string
  default     = "vpc-0cf7cb3b71fc48958"
}

variable "hub_vpc_cidr" {
  description = "CIDR block of the us-west-2 hub VPC"
  type        = string
  default     = "10.10.100.0/22"
}

variable "homelab_cidr" {
  description = "CIDR block of homelab network"
  type        = string
  default     = "10.10.192.0/19"
}

#------------------------------------------------------------------------------
# WireGuard Configuration
#------------------------------------------------------------------------------

variable "wg0_tunnel_ip" {
  description = "WireGuard wg0 tunnel IP for us-east-1 (from 10.255.255.0/29 range)"
  type        = string
  default     = "10.255.255.4"
}

variable "homelab_endpoint" {
  description = "Homelab WireGuard public endpoint"
  type        = string
  default     = "wind.etherport.net"
}

variable "homelab_wg0_port" {
  description = "Homelab WireGuard wg0 port (external port). Port 9820 avoids Twilio conflict."
  type        = number
  default     = 9820
}

variable "wg0_private_key" {
  description = "WireGuard wg0 private key for us-east-1. Generate with: wg genkey"
  type        = string
  sensitive   = true
  default     = ""
}

variable "wg0_public_key" {
  description = "WireGuard wg0 public key for us-east-1. Generate with: echo PRIVATE_KEY | wg pubkey"
  type        = string
  default     = ""
}

#------------------------------------------------------------------------------
# SSH Configuration
#------------------------------------------------------------------------------

variable "ssh_allowed_cidrs" {
  description = "CIDR blocks allowed for SSH access"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
