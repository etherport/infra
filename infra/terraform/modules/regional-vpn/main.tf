# Regional VPN Module
# Deploys a temporary WireGuard VPN endpoint in any AWS region
#
# Usage:
#   module "vpn_bahrain" {
#     source = "../modules/regional-vpn"
#     region = "me-south-1"
#     vpc_cidr = "10.10.112.0/24"
#     wg_private_key = var.wg_private_key
#     wg_peer_public_key = var.homelab_public_key
#     wg_peer_endpoint = "wind.etherport.net:51820"
#   }

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

locals {
  name_prefix = "vpn-${var.region_short}"
  common_tags = {
    Environment = "homelab"
    ManagedBy   = "terraform"
    Purpose     = "travel-vpn"
    Temporary   = "true"
  }
}

#------------------------------------------------------------------------------
# VPC and Networking
#------------------------------------------------------------------------------

resource "aws_vpc" "vpn" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-vpc"
  })
}

resource "aws_internet_gateway" "vpn" {
  vpc_id = aws_vpc.vpn.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-igw"
  })
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.vpn.id
  cidr_block              = var.vpc_cidr
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-public"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.vpn.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.vpn.id
  }

  # Route to homelab via WireGuard (handled by instance routing)
  # Route to us-west-2 via VPC peering (if enabled)
  dynamic "route" {
    for_each = var.enable_vpc_peering ? [1] : []
    content {
      cidr_block                = "10.10.100.0/22" # us-west-2 VPC
      vpc_peering_connection_id = aws_vpc_peering_connection.to_hub[0].id
    }
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-rt"
  })
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

data "aws_availability_zones" "available" {
  state = "available"
}

#------------------------------------------------------------------------------
# Security Group
#------------------------------------------------------------------------------

resource "aws_security_group" "vpn" {
  name        = "${local.name_prefix}-sg"
  description = "WireGuard VPN access"
  vpc_id      = aws_vpc.vpn.id

  # WireGuard
  ingress {
    from_port   = 51820
    to_port     = 51821
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "WireGuard VPN"
  }

  # SSH (restricted to your current IP - update as needed)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_allowed_cidrs
    description = "SSH access"
  }

  # All outbound
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-sg"
  })
}

#------------------------------------------------------------------------------
# EC2 Instance
#------------------------------------------------------------------------------

data "aws_ami" "ubuntu_arm" {
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

resource "aws_instance" "vpn" {
  ami                         = data.aws_ami.ubuntu_arm.id
  instance_type               = "t4g.nano"
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.vpn.id]
  associate_public_ip_address = true
  source_dest_check           = false # Required for VPN routing

  key_name = var.key_pair_name

  user_data = base64encode(templatefile("${path.module}/user-data.sh.tpl", {
    wg_private_key      = var.wg_private_key
    wg_address          = var.wg_address
    wg_peer_public_key  = var.wg_peer_public_key
    wg_peer_endpoint    = var.wg_peer_endpoint
    wg_peer_allowed_ips = var.wg_peer_allowed_ips
    client_public_key   = var.client_public_key
    client_allowed_ips  = var.client_allowed_ips
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

  tags = merge(local.common_tags, {
    Name = local.name_prefix
  })
}

#------------------------------------------------------------------------------
# Elastic IP (Optional - use for stable endpoint)
#------------------------------------------------------------------------------

resource "aws_eip" "vpn" {
  count    = var.use_elastic_ip ? 1 : 0
  domain   = "vpc"
  instance = aws_instance.vpn.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-eip"
  })
}

#------------------------------------------------------------------------------
# VPC Peering to us-west-2 (Optional)
#------------------------------------------------------------------------------

resource "aws_vpc_peering_connection" "to_hub" {
  count       = var.enable_vpc_peering ? 1 : 0
  vpc_id      = aws_vpc.vpn.id
  peer_vpc_id = var.hub_vpc_id
  peer_region = "us-west-2"
  auto_accept = false

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-to-hub"
  })
}

#------------------------------------------------------------------------------
# Route53 DNS record for the WireGuard endpoint (L2 fix)
#------------------------------------------------------------------------------
# Owns vpn-travel.etherport.net (or whichever FQDN is passed). Created
# on apply, deleted on destroy — closes the dangling-record issue
# from M38 / L2 where the regional-vpn module would tear down the
# EC2 + EIP but leave the DNS pointing at the freed-up IP for the
# Route53 record's TTL.
#
# Disabled by default so existing callers (and the existing dangling
# record under the route53 module's state) don't conflict. Enable per
# regional invocation by setting both var.dns_zone_id and var.dns_record_name.
#
# Migration path for a deploy that previously had the record managed
# by the route53 module: on next regional-vpn destroy, manually clean
# the orphan there + import the new resource here on the next apply
# via terraform import. Or just accept the duplicate apply-delete
# cycle once.

variable "dns_zone_id" {
  description = "Route53 hosted zone ID for the DNS record. Empty = no record created."
  type        = string
  default     = ""
}

variable "dns_record_name" {
  description = "FQDN to set as A record pointing at the EIP. E.g. vpn-travel.etherport.net. Empty = no record."
  type        = string
  default     = ""
}

variable "dns_record_ttl" {
  description = "TTL on the A record. Default 300s."
  type        = number
  default     = 300
}

resource "aws_route53_record" "vpn_endpoint" {
  count   = (var.dns_zone_id != "" && var.dns_record_name != "" && var.use_elastic_ip) ? 1 : 0
  zone_id = var.dns_zone_id
  name    = var.dns_record_name
  type    = "A"
  ttl     = var.dns_record_ttl
  records = [aws_eip.vpn[0].public_ip]

  # The eip count guard above prevents this from rendering when EIP
  # isn't allocated. Without an EIP the IP would change on every
  # instance restart and the DNS would be stale anyway.
}
