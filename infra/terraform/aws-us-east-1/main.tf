# AWS US-East-1 Hub Infrastructure
# VPC and Subnets - Mirrors us-west-2 architecture
#
# CIDR Allocations:
#   VPC:      10.10.104.0/22 (1024 IPs)
#   Public1:  10.10.104.0/25   (us-east-1a)
#   Public2:  10.10.104.128/25 (us-east-1b)
#   Private1: 10.10.105.0/24   (us-east-1a)
#   Private2: 10.10.106.0/24   (us-east-1b)
#
# WireGuard Tunnel IP: 10.255.255.4 (from /29 range)

locals {
  region      = "us-east-1"
  region_code = "use1"
  name_prefix = "us-east-1-infra"

  # Subnet configuration
  subnets = {
    public1 = {
      cidr = "10.10.104.0/25"
      az   = "us-east-1a"
      name = "${local.name_prefix}-subnet-public1-us-east-1a"
      type = "public"
    }
    public2 = {
      cidr = "10.10.104.128/25"
      az   = "us-east-1b"
      name = "${local.name_prefix}-subnet-public2-us-east-1b"
      type = "public"
    }
    private1 = {
      cidr = "10.10.105.0/24"
      az   = "us-east-1a"
      name = "${local.name_prefix}-subnet-private1-us-east-1a"
      type = "private"
    }
    private2 = {
      cidr = "10.10.106.0/24"
      az   = "us-east-1b"
      name = "${local.name_prefix}-subnet-private2-us-east-1b"
      type = "private"
    }
  }

  common_tags = {
    Region = local.region
  }
}

#------------------------------------------------------------------------------
# Data Sources
#------------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

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

# Load WireGuard keys from SOPS
# wg0 keys: unique to us-east-1 (for site-to-site tunnel to homelab)
# wg1 keys: shared with vpn-aws (for seamless endpoint switching)
data "sops_file" "use1_keys" {
  source_file = "${path.module}/../../../platform/wireguard/servers/vpn-use1.sops.yaml"
}

data "sops_file" "wg1_keys" {
  source_file = "${path.module}/../../../platform/wireguard/servers/vpn-aws.sops.yaml"
}

data "sops_file" "homelab_keys" {
  source_file = "${path.module}/../../../platform/wireguard/servers/vpn-local.sops.yaml"
}

# Client public key for remote access
locals {
  client_public_key = "7FAI4YiWGRtKDl3AaG+jxjf0vDVaTtUisf68nQRFozA="
}

#------------------------------------------------------------------------------
# VPC
#------------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-vpc"
  })
}

#------------------------------------------------------------------------------
# Subnets
#------------------------------------------------------------------------------

resource "aws_subnet" "public1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.subnets.public1.cidr
  availability_zone       = local.subnets.public1.az
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = local.subnets.public1.name
    Type = "public"
  })
}

resource "aws_subnet" "public2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.subnets.public2.cidr
  availability_zone       = local.subnets.public2.az
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = local.subnets.public2.name
    Type = "public"
  })
}

resource "aws_subnet" "private1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.subnets.private1.cidr
  availability_zone = local.subnets.private1.az

  tags = merge(local.common_tags, {
    Name = local.subnets.private1.name
    Type = "private"
  })
}

resource "aws_subnet" "private2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.subnets.private2.cidr
  availability_zone = local.subnets.private2.az

  tags = merge(local.common_tags, {
    Name = local.subnets.private2.name
    Type = "private"
  })
}

#------------------------------------------------------------------------------
# Internet Gateway
#------------------------------------------------------------------------------

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-igw"
  })
}

#------------------------------------------------------------------------------
# VPC Endpoint (S3 Gateway) - Cost optimization
#------------------------------------------------------------------------------

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [
    aws_route_table.private1.id,
    aws_route_table.private2.id,
  ]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-s3-endpoint"
  })
}

#------------------------------------------------------------------------------
# Route Tables
#------------------------------------------------------------------------------

# Public Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-rtb-public"
  })
}

# Internet Gateway route (IPv4)
resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

# Route to homelab via VPN instance
resource "aws_route" "public_to_homelab" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = var.homelab_cidr
  network_interface_id   = aws_instance.vpn.primary_network_interface_id
}

# Route to us-west-2 hub via VPC peering
resource "aws_route" "public_to_hub" {
  route_table_id            = aws_route_table.public.id
  destination_cidr_block    = var.hub_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.to_hub.id

  depends_on = [aws_vpc_peering_connection_accepter.hub]
}

# Associate public subnets
resource "aws_route_table_association" "public1" {
  subnet_id      = aws_subnet.public1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public2" {
  subnet_id      = aws_subnet.public2.id
  route_table_id = aws_route_table.public.id
}

# Private Route Table 1 (us-east-1a)
resource "aws_route_table" "private1" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-rtb-private1-us-east-1a"
  })
}

resource "aws_route_table_association" "private1" {
  subnet_id      = aws_subnet.private1.id
  route_table_id = aws_route_table.private1.id
}

# Private Route Table 2 (us-east-1b)
resource "aws_route_table" "private2" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-rtb-private2-us-east-1b"
  })
}

resource "aws_route_table_association" "private2" {
  subnet_id      = aws_subnet.private2.id
  route_table_id = aws_route_table.private2.id
}

#------------------------------------------------------------------------------
# Network ACL (Default - applied to all subnets)
#------------------------------------------------------------------------------

resource "aws_default_network_acl" "main" {
  default_network_acl_id = aws_vpc.main.default_network_acl_id

  subnet_ids = [
    aws_subnet.public1.id,
    aws_subnet.public2.id,
    aws_subnet.private1.id,
    aws_subnet.private2.id,
  ]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-nacl-main"
  })

  #----------------------------------------------------------------------------
  # Egress Rules (Outbound)
  #----------------------------------------------------------------------------

  # Allow all outbound IPv4
  egress {
    rule_no    = 100
    protocol   = "-1"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  #----------------------------------------------------------------------------
  # Ingress Rules (Inbound)
  #----------------------------------------------------------------------------

  # DNS TCP (IPv4)
  ingress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 53
    to_port    = 53
  }

  # DNS UDP (IPv4)
  ingress {
    rule_no    = 101
    protocol   = "udp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 53
    to_port    = 53
  }

  # HTTPS (IPv4)
  ingress {
    rule_no    = 102
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 443
    to_port    = 443
  }

  # WireGuard UDP (site-to-site and remote access)
  ingress {
    rule_no    = 103
    protocol   = "udp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 51820
    to_port    = 51821
  }

  # Homelab network (all traffic)
  ingress {
    rule_no    = 104
    protocol   = "-1"
    action     = "allow"
    cidr_block = var.homelab_cidr
    from_port  = 0
    to_port    = 0
  }

  # Hub VPC (all traffic)
  ingress {
    rule_no    = 105
    protocol   = "-1"
    action     = "allow"
    cidr_block = var.hub_vpc_cidr
    from_port  = 0
    to_port    = 0
  }

  # VPC CIDR (all traffic)
  ingress {
    rule_no    = 106
    protocol   = "-1"
    action     = "allow"
    cidr_block = var.vpc_cidr
    from_port  = 0
    to_port    = 0
  }

  # Remote VPN clients (all traffic)
  ingress {
    rule_no    = 107
    protocol   = "-1"
    action     = "allow"
    cidr_block = "10.254.0.0/24"
    from_port  = 0
    to_port    = 0
  }

  # SSH (IPv4)
  ingress {
    rule_no    = 108
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 22
    to_port    = 22
  }

  # Ephemeral ports TCP (IPv4)
  ingress {
    rule_no    = 109
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  # Ephemeral ports UDP (IPv4)
  ingress {
    rule_no    = 110
    protocol   = "udp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  # ICMP (IPv4)
  ingress {
    rule_no    = 111
    protocol   = "icmp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    icmp_type  = -1
    icmp_code  = -1
    from_port  = 0
    to_port    = 0
  }
}

#------------------------------------------------------------------------------
# Security Groups
#------------------------------------------------------------------------------

# Default Security Group (deny all)
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-default-sg"
  })
}

# VPN Server Security Group
resource "aws_security_group" "vpn_server" {
  name        = "${local.name_prefix}-vpn-server-sg"
  description = "Allow WireGuard VPN access"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-vpn-server-sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "vpn_wireguard" {
  security_group_id = aws_security_group.vpn_server.id
  description       = "WireGuard VPN access (site-to-site and remote)"
  ip_protocol       = "udp"
  from_port         = 51820
  to_port           = 51821
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "vpn_from_hub" {
  security_group_id = aws_security_group.vpn_server.id
  description       = "All traffic from hub VPC"
  ip_protocol       = "-1"
  cidr_ipv4         = var.hub_vpc_cidr
}

resource "aws_vpc_security_group_ingress_rule" "vpn_from_homelab" {
  security_group_id = aws_security_group.vpn_server.id
  description       = "All traffic from homelab"
  ip_protocol       = "-1"
  cidr_ipv4         = var.homelab_cidr
}

resource "aws_vpc_security_group_ingress_rule" "vpn_from_clients" {
  security_group_id = aws_security_group.vpn_server.id
  description       = "All traffic from VPN clients"
  ip_protocol       = "-1"
  cidr_ipv4         = "10.254.0.0/24"
}

resource "aws_vpc_security_group_egress_rule" "vpn_all_ipv4" {
  security_group_id = aws_security_group.vpn_server.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "vpn_all_ipv6" {
  security_group_id = aws_security_group.vpn_server.id
  ip_protocol       = "-1"
  cidr_ipv6         = "::/0"
}

# SSH Access Security Group
resource "aws_security_group" "allow_ssh" {
  name        = "${local.name_prefix}-allow-ssh-sg"
  description = "Allow SSH access"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-allow-ssh-sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "ssh_all" {
  security_group_id = aws_security_group.allow_ssh.id
  description       = "SSH access"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "ssh_all_ipv4" {
  security_group_id = aws_security_group.allow_ssh.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# Internal Communications Security Group
resource "aws_security_group" "internal_comms" {
  name        = "${local.name_prefix}-internal-comms-sg"
  description = "Allow private communications within VPC and trusted networks"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-internal-comms-sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "internal_vpc" {
  security_group_id = aws_security_group.internal_comms.id
  description       = "All traffic from VPC"
  ip_protocol       = "-1"
  cidr_ipv4         = var.vpc_cidr
}

resource "aws_vpc_security_group_ingress_rule" "internal_hub" {
  security_group_id = aws_security_group.internal_comms.id
  description       = "All traffic from hub VPC"
  ip_protocol       = "-1"
  cidr_ipv4         = var.hub_vpc_cidr
}

resource "aws_vpc_security_group_ingress_rule" "internal_homelab" {
  security_group_id = aws_security_group.internal_comms.id
  description       = "All traffic from homelab"
  ip_protocol       = "-1"
  cidr_ipv4         = var.homelab_cidr
}

resource "aws_vpc_security_group_ingress_rule" "internal_vpn_clients" {
  security_group_id = aws_security_group.internal_comms.id
  description       = "All traffic from VPN clients"
  ip_protocol       = "-1"
  cidr_ipv4         = "10.254.0.0/24"
}

resource "aws_vpc_security_group_egress_rule" "internal_all_ipv4" {
  security_group_id = aws_security_group.internal_comms.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "internal_all_ipv6" {
  security_group_id = aws_security_group.internal_comms.id
  ip_protocol       = "-1"
  cidr_ipv6         = "::/0"
}

#------------------------------------------------------------------------------
# VPC Peering to us-west-2 Hub
#------------------------------------------------------------------------------

resource "aws_vpc_peering_connection" "to_hub" {
  vpc_id        = aws_vpc.main.id
  peer_vpc_id   = var.hub_vpc_id
  peer_region   = "us-west-2"
  auto_accept   = false

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-to-hub-peering"
    Side = "Requester"
  })
}

# Accept peering in us-west-2
resource "aws_vpc_peering_connection_accepter" "hub" {
  provider                  = aws.hub
  vpc_peering_connection_id = aws_vpc_peering_connection.to_hub.id
  auto_accept               = true

  tags = {
    Name        = "${local.name_prefix}-to-hub-peering"
    Side        = "Accepter"
    Environment = "homelab"
    ManagedBy   = "terraform"
  }
}

# Route from hub to us-east-1 VPC
resource "aws_route" "hub_to_use1" {
  provider                  = aws.hub
  route_table_id            = data.aws_route_tables.hub_public.ids[0]
  destination_cidr_block    = var.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.to_hub.id

  depends_on = [aws_vpc_peering_connection_accepter.hub]
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
# Key Pair (reference existing)
#------------------------------------------------------------------------------

data "aws_key_pair" "main" {
  key_name = "GS-EC2"
}

#------------------------------------------------------------------------------
# Elastic IP for VPN Instance
#------------------------------------------------------------------------------

resource "aws_eip" "vpn" {
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-vpn-eip"
  })
}

resource "aws_eip_association" "vpn" {
  instance_id   = aws_instance.vpn.id
  allocation_id = aws_eip.vpn.id
}

#------------------------------------------------------------------------------
# VPN Instance
#------------------------------------------------------------------------------

resource "aws_instance" "vpn" {
  ami                         = data.aws_ami.ubuntu_arm.id
  instance_type               = "t4g.nano"
  subnet_id                   = aws_subnet.public1.id
  vpc_security_group_ids      = [
    aws_security_group.vpn_server.id,
    aws_security_group.allow_ssh.id,
    aws_security_group.internal_comms.id,
  ]
  associate_public_ip_address = false  # Using Elastic IP
  source_dest_check           = false  # Required for routing

  key_name = data.aws_key_pair.main.key_name

  user_data = base64encode(templatefile("${path.module}/user-data.sh.tpl", {
    # wg0 - Direct tunnel to homelab (unique keys for us-east-1)
    wg0_private_key        = data.sops_file.use1_keys.data["stringData.wg0_private_key"]
    wg0_tunnel_ip          = var.wg0_tunnel_ip
    homelab_wg0_public_key = data.sops_file.homelab_keys.data["stringData.wg0_public_key"]
    homelab_endpoint       = var.homelab_endpoint
    homelab_wg0_port       = var.homelab_wg0_port
    homelab_cidr           = var.homelab_cidr
    # wg1 - Remote access (shared keys with vpn-aws for endpoint switching)
    wg1_private_key        = data.sops_file.wg1_keys.data["stringData.wg1_private_key"]
    client_public_key      = local.client_public_key
    aws_vpc_cidr           = var.hub_vpc_cidr
    local_vpc_cidr         = var.vpc_cidr
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
    Name = "${local.name_prefix}-vpn"
  })

  depends_on = [
    aws_vpc_peering_connection_accepter.hub,
    aws_route.hub_to_use1,
  ]
}
