# Regional VPN Deployment
# Quick-deploy WireGuard VPN in any AWS region for travel
#
# Usage:
#   # Deploy to Bahrain (closest to Abu Dhabi)
#   cd infra/terraform/aws-regional-vpn
#   terraform init
#   terraform apply -var="region=me-south-1" -var="region_short=bah"
#
#   # Get connection info
#   terraform output -raw wireguard_client_config
#
#   # Destroy when done (stop paying!)
#   terraform destroy -var="region=me-south-1" -var="region_short=bah"

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.0"
    }
  }

  # State stored locally - this is temporary infrastructure
  # Or use remote state if you want to manage from multiple machines:
  # backend "s3" {
  #   bucket         = "terraform.wind.etherport.net"
  #   key            = "aws-regional-vpn/terraform.tfstate"
  #   region         = "us-west-2"
  #   use_lockfile   = true
  # }
}

#------------------------------------------------------------------------------
# Variables
#------------------------------------------------------------------------------

variable "region" {
  description = "AWS region to deploy VPN"
  type        = string
  default     = "me-south-1"  # Bahrain - closest to UAE
}

variable "region_short" {
  description = "Short region name for resource naming"
  type        = string
  default     = "bah"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.10.112.0/24"
}

#------------------------------------------------------------------------------
# Provider
#------------------------------------------------------------------------------

provider "aws" {
  region  = var.region
  profile = "homelab"

  default_tags {
    tags = {
      Environment = "homelab"
      ManagedBy   = "terraform"
      Purpose     = "travel-vpn"
    }
  }
}

provider "sops" {}

#------------------------------------------------------------------------------
# Load WireGuard keys from SOPS
#------------------------------------------------------------------------------

# Use vpn-aws keys for consistency (same keys work across all regional VPNs)
data "sops_file" "wg_keys" {
  source_file = "${path.module}/../../../platform/wireguard/servers/vpn-aws.sops.yaml"
}

# Client keys (your device)
data "sops_file" "client_keys" {
  source_file = "${path.module}/../../../platform/wireguard/clients/graham.sops.yaml"
}

# Homelab keys (peer)
data "sops_file" "homelab_keys" {
  source_file = "${path.module}/../../../platform/wireguard/servers/vpn-local.sops.yaml"
}

#------------------------------------------------------------------------------
# Regional VPN Module
#------------------------------------------------------------------------------

module "vpn" {
  source = "../modules/regional-vpn"

  region_short = var.region_short
  vpc_cidr     = var.vpc_cidr

  # WireGuard configuration
  wg_private_key      = data.sops_file.wg_keys.data["stringData.wg0_private_key"]
  wg_address          = "10.255.255.5/30"  # New tunnel IP for regional VPNs
  wg_peer_public_key  = data.sops_file.homelab_keys.data["stringData.wg0_public_key"]
  wg_peer_endpoint    = "wind.etherport.net:51820"
  wg_peer_allowed_ips = "10.10.192.0/19,10.255.255.0/30"

  # Your device for remote access
  client_public_key  = data.sops_file.client_keys.data["stringData.public_key"]
  client_allowed_ips = "10.254.0.10/32"

  # No EIP - save costs, use dynamic IP
  use_elastic_ip = false

  # SSH access - restrict to VPN or Tailscale
  ssh_allowed_cidrs = ["0.0.0.0/0"]  # Update with your current IP
}

#------------------------------------------------------------------------------
# Outputs
#------------------------------------------------------------------------------

output "vpn_public_ip" {
  description = "VPN server public IP - use as WireGuard endpoint"
  value       = module.vpn.public_ip
}

output "ssh_command" {
  description = "SSH command to connect"
  value       = module.vpn.ssh_command
}

output "wireguard_endpoint" {
  description = "WireGuard endpoint for client config"
  value       = "${module.vpn.public_ip}:51821"
}

output "client_config_instructions" {
  description = "How to configure your device"
  value       = <<-EOT

    === WireGuard Client Configuration ===

    Add this peer to your existing remote-access config,
    or create a new config for travel:

    [Peer]
    # vpn-${var.region_short} (${var.region})
    PublicKey = <vpn-aws public key from SOPS>
    Endpoint = ${module.vpn.public_ip}:51821
    AllowedIPs = 0.0.0.0/0
    PersistentKeepalive = 25

    Or for split tunnel (homelab only):
    AllowedIPs = 10.10.192.0/19, 10.10.100.0/22

  EOT
}

output "estimated_daily_cost" {
  description = "Estimated cost while running"
  value       = "$0.10/day (t4g.nano hourly rate)"
}
