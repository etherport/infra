# Regional VPN Deployment with Direct Homelab Tunnel
# Deploys WireGuard VPN in any AWS region with:
#   - wg0: Direct tunnel to homelab (VPC peering doesn't support transit routing)
#   - wg1: Remote access for clients
#   - VPC Peering: For AWS us-west-2 traffic only
#
# Architecture:
#   Your Device → vpn-regional (wg1) → wg0 → homelab
#                                    → VPC Peering → us-west-2 (for AWS resources)
#
# Usage:
#   cd infra/terraform/aws-regional-vpn
#   terraform init
#   terraform apply -var="region=ap-south-1" -var="region_short=mumbai" -var="wg0_tunnel_ip=10.255.255.3"
#
#   # When done traveling
#   terraform destroy -var="region=ap-south-1" -var="region_short=mumbai" -var="wg0_tunnel_ip=10.255.255.3"
#
# Tunnel IP Assignments (10.255.255.0/29):
#   - .1 = vpn-aws (us-west-2)
#   - .2 = homelab
#   - .3 = Mumbai (ap-south-1)
#   - .4 = next region
#   - .5 = next region
#   - .6 = next region

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

  # Remote state for persistence across machines
  backend "s3" {
    bucket       = "terraform.wind.etherport.net"
    key          = "aws-regional-vpn/terraform.tfstate"
    region       = "us-west-2"
    use_lockfile = true
    profile      = "homelab"
  }
}

#------------------------------------------------------------------------------
# Variables
#------------------------------------------------------------------------------

variable "region" {
  description = "AWS region to deploy VPN"
  type        = string
  default     = "me-central-1"  # UAE - Abu Dhabi
}

variable "region_short" {
  description = "Short region name for resource naming"
  type        = string
  default     = "uae"
}

variable "aws_profile" {
  description = "AWS profile to use (empty string for environment variables)"
  type        = string
  default     = "homelab"
}

variable "vpc_cidr" {
  description = "VPC CIDR block for regional VPN"
  type        = string
  default     = "10.10.112.0/24"
}

variable "hub_vpc_id" {
  description = "VPC ID of us-west-2 hub"
  type        = string
  default     = "vpc-0cf7cb3b71fc48958"
}

variable "hub_route_table_id" {
  description = "Public route table ID in us-west-2 hub"
  type        = string
  default     = "rtb-0a3c3a2a4c8f5e123"  # Will get actual ID
}

variable "ssh_public_key" {
  description = "SSH public key for EC2 access (contents of ~/.ssh/gs-ec2.pub)"
  type        = string
  sensitive   = true
  default     = ""  # Set via TF_VAR_ssh_public_key or terraform.tfvars
}

variable "wg0_tunnel_ip" {
  description = "WireGuard wg0 tunnel IP for this region (from 10.255.255.0/29 range)"
  type        = string
  # Assignments:
  #   .1 = vpn-aws (us-west-2)
  #   .2 = homelab
  #   .3 = Mumbai (ap-south-1)
  #   .4-6 = future regions
}

variable "homelab_endpoint" {
  description = "Homelab WireGuard public endpoint (IP or hostname)"
  type        = string
  default     = "47.159.189.5"  # Homelab public IP
}

variable "homelab_wg0_port" {
  description = "Homelab WireGuard wg0 port (external port forwarded through UDM). Port 9820 is used to avoid conflict with Twilio range (10000-60000)."
  type        = number
  default     = 9820  # UDM forwards 9820 → VIP:51820
}

variable "wg0_private_key" {
  description = "WireGuard wg0 private key for this regional instance. Generate with: wg genkey"
  type        = string
  sensitive   = true
  default     = ""  # Set via TF_VAR_wg0_private_key or terraform.tfvars
}

variable "wg0_public_key" {
  description = "WireGuard wg0 public key (derived from private key). Generate with: echo PRIVATE_KEY | wg pubkey"
  type        = string
  default     = ""  # Set via TF_VAR_wg0_public_key or terraform.tfvars
}

#------------------------------------------------------------------------------
# Providers - Regional VPN and Hub (us-west-2)
#------------------------------------------------------------------------------

provider "aws" {
  alias   = "regional"
  region  = var.region
  profile = var.aws_profile != "" ? var.aws_profile : null

  default_tags {
    tags = {
      Environment = "homelab"
      ManagedBy   = "terraform"
      Purpose     = "travel-vpn"
      Temporary   = "true"
    }
  }
}

provider "aws" {
  alias   = "hub"
  region  = "us-west-2"
  profile = var.aws_profile != "" ? var.aws_profile : null

  default_tags {
    tags = {
      Environment = "homelab"
      ManagedBy   = "terraform"
    }
  }
}

provider "sops" {}

#------------------------------------------------------------------------------
# Load WireGuard keys from SOPS
#------------------------------------------------------------------------------

data "sops_file" "wg_keys" {
  source_file = "${path.module}/../../../platform/wireguard/servers/vpn-aws.sops.yaml"
}

# Client public key - extracted from platform/kubernetes/wireguard/03-deployment.yaml
# This is Graham's WireGuard public key for remote access
locals {
  client_public_key = "7FAI4YiWGRtKDl3AaG+jxjf0vDVaTtUisf68nQRFozA="
}

data "sops_file" "homelab_keys" {
  source_file = "${path.module}/../../../platform/wireguard/servers/vpn-local.sops.yaml"
}

#------------------------------------------------------------------------------
# Data Sources
#------------------------------------------------------------------------------

data "aws_availability_zones" "regional" {
  provider = aws.regional
  state    = "available"
}

data "aws_ami" "ubuntu_arm" {
  provider    = aws.regional
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Get hub VPC details
data "aws_vpc" "hub" {
  provider = aws.hub
  id       = var.hub_vpc_id
}

# Get hub public route table
data "aws_route_tables" "hub_public" {
  provider = aws.hub
  vpc_id   = var.hub_vpc_id

  filter {
    name   = "tag:Name"
    values = ["private-infra-rtb-public"]
  }
}

#------------------------------------------------------------------------------
# Regional VPC
#------------------------------------------------------------------------------

resource "aws_vpc" "regional" {
  provider             = aws.regional
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "vpn-${var.region_short}-vpc"
  }
}

resource "aws_internet_gateway" "regional" {
  provider = aws.regional
  vpc_id   = aws_vpc.regional.id

  tags = {
    Name = "vpn-${var.region_short}-igw"
  }
}

resource "aws_subnet" "regional" {
  provider                = aws.regional
  vpc_id                  = aws_vpc.regional.id
  cidr_block              = var.vpc_cidr
  availability_zone       = data.aws_availability_zones.regional.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "vpn-${var.region_short}-public"
  }
}

#------------------------------------------------------------------------------
# VPC Peering Connection
#------------------------------------------------------------------------------

resource "aws_vpc_peering_connection" "to_hub" {
  provider      = aws.regional
  vpc_id        = aws_vpc.regional.id
  peer_vpc_id   = var.hub_vpc_id
  peer_region   = "us-west-2"
  auto_accept   = false

  tags = {
    Name = "vpn-${var.region_short}-to-hub"
    Side = "Requester"
  }
}

# Accept peering in us-west-2
resource "aws_vpc_peering_connection_accepter" "hub" {
  provider                  = aws.hub
  vpc_peering_connection_id = aws_vpc_peering_connection.to_hub.id
  auto_accept               = true

  tags = {
    Name = "vpn-${var.region_short}-to-hub"
    Side = "Accepter"
  }
}

#------------------------------------------------------------------------------
# Route Tables - Regional Side
#------------------------------------------------------------------------------

resource "aws_route_table" "regional" {
  provider = aws.regional
  vpc_id   = aws_vpc.regional.id

  tags = {
    Name = "vpn-${var.region_short}-rt"
  }
}

# Internet route
resource "aws_route" "regional_internet" {
  provider               = aws.regional
  route_table_id         = aws_route_table.regional.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.regional.id
}

# Route to us-west-2 VPC via peering
resource "aws_route" "regional_to_hub_vpc" {
  provider                  = aws.regional
  route_table_id            = aws_route_table.regional.id
  destination_cidr_block    = "10.10.100.0/22"
  vpc_peering_connection_id = aws_vpc_peering_connection.to_hub.id

  depends_on = [aws_vpc_peering_connection_accepter.hub]
}

# Route to homelab via peering (hub will forward via wg0)
resource "aws_route" "regional_to_homelab" {
  provider                  = aws.regional
  route_table_id            = aws_route_table.regional.id
  destination_cidr_block    = "10.10.192.0/19"
  vpc_peering_connection_id = aws_vpc_peering_connection.to_hub.id

  depends_on = [aws_vpc_peering_connection_accepter.hub]
}

resource "aws_route_table_association" "regional" {
  provider       = aws.regional
  subnet_id      = aws_subnet.regional.id
  route_table_id = aws_route_table.regional.id
}

#------------------------------------------------------------------------------
# Route Tables - Hub Side (us-west-2)
#------------------------------------------------------------------------------

# Route from hub to regional VPC
resource "aws_route" "hub_to_regional" {
  provider                  = aws.hub
  route_table_id            = data.aws_route_tables.hub_public.ids[0]
  destination_cidr_block    = var.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.to_hub.id

  depends_on = [aws_vpc_peering_connection_accepter.hub]
}

#------------------------------------------------------------------------------
# Key Pair (reference existing - imported via console)
#------------------------------------------------------------------------------

data "aws_key_pair" "regional" {
  provider = aws.regional
  key_name = "GS-EC2"
}

#------------------------------------------------------------------------------
# Security Group
#------------------------------------------------------------------------------

resource "aws_security_group" "vpn" {
  provider    = aws.regional
  name        = "vpn-${var.region_short}-sg"
  description = "WireGuard VPN access"
  vpc_id      = aws_vpc.regional.id

  # WireGuard wg0 (site-to-site tunnel from homelab)
  ingress {
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "WireGuard site-to-site"
  }

  # WireGuard wg1 (remote access for clients)
  ingress {
    from_port   = 51821
    to_port     = 51821
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "WireGuard remote access"
  }

  # SSH
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "SSH access"
  }

  # Allow from hub VPC (for health checks, etc.)
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.10.100.0/22"]
    description = "From hub VPC"
  }

  # All outbound
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "vpn-${var.region_short}-sg"
  }
}

#------------------------------------------------------------------------------
# EC2 Instance
#------------------------------------------------------------------------------

resource "aws_instance" "vpn" {
  provider                    = aws.regional
  ami                         = data.aws_ami.ubuntu_arm.id
  instance_type               = "t4g.nano"
  subnet_id                   = aws_subnet.regional.id
  vpc_security_group_ids      = [aws_security_group.vpn.id]
  associate_public_ip_address = true
  source_dest_check           = false  # Required for routing

  key_name = data.aws_key_pair.regional.key_name

  user_data = base64encode(templatefile("${path.module}/user-data.sh.tpl", {
    # wg0 - Direct tunnel to homelab (unique keys per region)
    wg0_private_key        = var.wg0_private_key
    wg0_tunnel_ip          = var.wg0_tunnel_ip
    homelab_wg0_public_key = data.sops_file.homelab_keys.data["stringData.wg0_public_key"]
    homelab_endpoint       = var.homelab_endpoint
    homelab_wg0_port       = var.homelab_wg0_port
    homelab_cidr           = "10.10.192.0/19"
    # wg1 - Remote access (shares keys with vpn-aws for seamless endpoint switching)
    wg1_private_key        = data.sops_file.wg_keys.data["stringData.wg1_private_key"]
    client_public_key      = local.client_public_key
    aws_vpc_cidr           = "10.10.100.0/22"
  }))

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size           = 8
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name = "vpn-${var.region_short}"
  }

  depends_on = [
    aws_vpc_peering_connection_accepter.hub,
    aws_route.regional_to_hub_vpc,
    aws_route.regional_to_homelab,
  ]
}

#------------------------------------------------------------------------------
# Outputs
#------------------------------------------------------------------------------

output "vpn_public_ip" {
  description = "VPN server public IP - use as WireGuard endpoint"
  value       = aws_instance.vpn.public_ip
}

output "vpn_private_ip" {
  description = "VPN server private IP within regional VPC"
  value       = aws_instance.vpn.private_ip
}

output "vpc_peering_id" {
  description = "VPC peering connection ID"
  value       = aws_vpc_peering_connection.to_hub.id
}

output "ssh_command" {
  description = "SSH command to connect"
  value       = "ssh -i ~/.ssh/gs-ec2.pem ubuntu@${aws_instance.vpn.public_ip}"
}

output "wireguard_endpoint" {
  description = "WireGuard endpoint for client config"
  value       = "${aws_instance.vpn.public_ip}:51821"
}

output "traffic_flow" {
  description = "Traffic routing explanation"
  value       = <<-EOT

    === Traffic Flow ===

    Your Device (10.254.0.10)
         │
         │ WireGuard wg1
         ▼
    vpn-${var.region_short} (${var.region})
         │
         ├── Internet → NAT → local IP (fast, local egress)
         │
         ├── AWS VPC (10.10.100.0/22) → VPC Peering → us-west-2
         │
         └── Homelab (10.10.192.0/19) → wg0 tunnel → homelab

    Note: Homelab traffic uses direct wg0 tunnel because VPC peering
    doesn't support transit routing through vpn-aws.

  EOT
}

output "homelab_peer_config" {
  description = "Add this peer to homelab's wireguard deployment"
  value       = <<-EOT

    === Add to homelab wireguard 03-deployment.yaml ===

    [Peer]
    # vpn-${var.region_short} (${var.region})
    PublicKey = ${var.wg0_public_key}
    AllowedIPs = ${var.vpc_cidr}, ${var.wg0_tunnel_ip}/32
    PersistentKeepalive = 25

  EOT
}

output "client_config" {
  description = "WireGuard client configuration"
  sensitive   = true
  value       = <<-EOT
    # Save as ~/.wireguard/travel-${var.region_short}.conf
    #
    # DNS: Using dns-aws (10.10.100.5) which can resolve internal names
    # and forwards to public DNS. Fallback to 1.1.1.1 if dns-aws is down.

    [Interface]
    PrivateKey = <your private key from 1Password>
    Address = 10.254.0.10/32
    DNS = 10.10.100.5, 1.1.1.1

    [Peer]
    # vpn-${var.region_short} (${var.region})
    PublicKey = ${data.sops_file.wg_keys.data["stringData.wg1_public_key"]}
    Endpoint = ${aws_instance.vpn.public_ip}:51821
    AllowedIPs = 0.0.0.0/0
    PersistentKeepalive = 25
  EOT
}

output "estimated_cost" {
  description = "Estimated costs"
  value       = <<-EOT
    Instance (t4g.nano): ~$0.10/day
    Public IPv4:         ~$0.12/day
    Total:               ~$0.22/day while running
  EOT
}

output "deployment_steps" {
  description = "Steps to deploy a new regional VPN"
  value       = <<-EOT

    === Deployment Steps ===

    1. Generate new WireGuard keys for wg0:
       wg genkey | tee /tmp/wg0.key | wg pubkey > /tmp/wg0.pub

    2. Add peer to homelab wireguard 03-deployment.yaml (see homelab_peer_config output)

    3. Apply homelab changes:
       kubectl apply -f platform/kubernetes/wireguard/03-deployment.yaml

    4. Deploy regional VPN:
       cd infra/terraform/aws-regional-vpn
       terraform apply \
         -var="region=${var.region}" \
         -var="region_short=${var.region_short}" \
         -var="wg0_tunnel_ip=${var.wg0_tunnel_ip}" \
         -var="wg0_private_key=$(cat /tmp/wg0.key)" \
         -var="wg0_public_key=$(cat /tmp/wg0.pub)"

    5. Verify connectivity:
       ssh ubuntu@<public_ip> 'ping -c 2 10.10.199.1'

    6. Update client WireGuard config with new endpoint

    === Teardown ===

    terraform destroy -var="region=${var.region}" -var="region_short=${var.region_short}" -var="wg0_tunnel_ip=${var.wg0_tunnel_ip}"

  EOT
}
