# AWS Networking Infrastructure
# Manages the private-infra VPC and associated resources

locals {
  vpc_cidr      = "10.10.100.0/22"
  vpc_ipv6_cidr = "2600:1f14:244d:2700::/56"

  # Subnet configuration
  subnets = {
    public1 = {
      cidr        = "10.10.100.0/25"
      ipv6_cidr   = "2600:1f14:244d:2700::/64"
      az          = "us-west-2a"
      name        = "private-infra-subnet-public1-us-west-2a"
      type        = "public"
    }
    public2 = {
      cidr        = "10.10.100.128/25"
      ipv6_cidr   = "2600:1f14:244d:2701::/64"
      az          = "us-west-2b"
      name        = "private-infra-subnet-public2-us-west-2b"
      type        = "public"
    }
    private1 = {
      cidr        = "10.10.101.0/24"
      ipv6_cidr   = "2600:1f14:244d:2702::/64"
      az          = "us-west-2a"
      name        = "private-infra-subnet-private1-us-west-2a"
      type        = "private"
    }
    private2 = {
      cidr        = "10.10.102.0/24"
      ipv6_cidr   = "2600:1f14:244d:2703::/64"
      az          = "us-west-2b"
      name        = "private-infra-subnet-private2-us-west-2b"
      type        = "private"
    }
  }

  common_tags = {
    Environment = "homelab"
    ManagedBy   = "terraform"
    Module      = "networking"
  }
}

#------------------------------------------------------------------------------
# VPC
#------------------------------------------------------------------------------

resource "aws_vpc" "private_infra" {
  cidr_block                       = local.vpc_cidr
  enable_dns_hostnames             = true
  enable_dns_support               = true
  assign_generated_ipv6_cidr_block = true

  tags = merge(local.common_tags, {
    Name = "private-infra-vpc"
  })

  # Prevent Terraform from trying to modify existing IPv6 allocation
  lifecycle {
    ignore_changes = [
      ipv6_cidr_block,
      ipv6_ipam_pool_id,
      ipv6_netmask_length,
    ]
  }
}

#------------------------------------------------------------------------------
# Subnets
#------------------------------------------------------------------------------

resource "aws_subnet" "public1" {
  vpc_id                          = aws_vpc.private_infra.id
  cidr_block                      = local.subnets.public1.cidr
  ipv6_cidr_block                 = local.subnets.public1.ipv6_cidr
  availability_zone               = local.subnets.public1.az
  map_public_ip_on_launch         = false
  assign_ipv6_address_on_creation = false

  tags = merge(local.common_tags, {
    Name = local.subnets.public1.name
    Type = "public"
  })
}

resource "aws_subnet" "public2" {
  vpc_id                          = aws_vpc.private_infra.id
  cidr_block                      = local.subnets.public2.cidr
  ipv6_cidr_block                 = local.subnets.public2.ipv6_cidr
  availability_zone               = local.subnets.public2.az
  map_public_ip_on_launch         = false
  assign_ipv6_address_on_creation = false

  tags = merge(local.common_tags, {
    Name = local.subnets.public2.name
    Type = "public"
  })
}

resource "aws_subnet" "private1" {
  vpc_id                          = aws_vpc.private_infra.id
  cidr_block                      = local.subnets.private1.cidr
  ipv6_cidr_block                 = local.subnets.private1.ipv6_cidr
  availability_zone               = local.subnets.private1.az
  map_public_ip_on_launch         = false
  assign_ipv6_address_on_creation = false

  tags = merge(local.common_tags, {
    Name = local.subnets.private1.name
    Type = "private"
  })
}

resource "aws_subnet" "private2" {
  vpc_id                          = aws_vpc.private_infra.id
  cidr_block                      = local.subnets.private2.cidr
  ipv6_cidr_block                 = local.subnets.private2.ipv6_cidr
  availability_zone               = local.subnets.private2.az
  map_public_ip_on_launch         = false
  assign_ipv6_address_on_creation = false

  tags = merge(local.common_tags, {
    Name = local.subnets.private2.name
    Type = "private"
  })
}

#------------------------------------------------------------------------------
# Internet Gateway
#------------------------------------------------------------------------------

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.private_infra.id

  tags = merge(local.common_tags, {
    Name = "private-infra-igw"
  })
}

#------------------------------------------------------------------------------
# VPC Endpoint (S3 Gateway)
#------------------------------------------------------------------------------

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.private_infra.id
  service_name      = "com.amazonaws.us-west-2.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [
    aws_route_table.private1.id,
    aws_route_table.private2.id,
  ]

  tags = merge(local.common_tags, {
    Name = "private-infra-s3-endpoint"
  })
}
