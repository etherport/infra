# Route Tables for private-infra VPC

#------------------------------------------------------------------------------
# Variables for VPN routing
#------------------------------------------------------------------------------

# VPN instance network interface ID - hardcoded until Phase 2 (EC2 module)
# Instance: i-0f81ff99edc6ede03 (private-infra_vpn)
locals {
  vpn_network_interface_id = "eni-076e0f855091d42a4"
}

#------------------------------------------------------------------------------
# Main Route Table (default)
#------------------------------------------------------------------------------

resource "aws_route_table" "main" {
  vpc_id = aws_vpc.private_infra.id

  tags = merge(local.common_tags, {
    Name = "private-infra-rtb-main"
  })
}

# Note: Main route table association cannot be imported
# The VPC's main route table is implicitly associated

#------------------------------------------------------------------------------
# Public Route Table
#------------------------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.private_infra.id

  tags = merge(local.common_tags, {
    Name = "private-infra-rtb-public"
  })
}

# Internet Gateway route (IPv4)
resource "aws_route" "public_internet_ipv4" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

# Internet Gateway route (IPv6)
resource "aws_route" "public_internet_ipv6" {
  route_table_id              = aws_route_table.public.id
  destination_ipv6_cidr_block = "::/0"
  gateway_id                  = aws_internet_gateway.main.id
}

# Route to homelab network via VPN instance
resource "aws_route" "public_to_homelab" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "10.10.192.0/19"
  network_interface_id   = local.vpn_network_interface_id
}

# Route to remote VPN clients via VPN instance
resource "aws_route" "public_to_vpn_clients" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "10.254.0.0/24"
  network_interface_id   = local.vpn_network_interface_id
}

# Route to S2S VPN via VPN instance
resource "aws_route" "public_to_s2s_vpn" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "10.255.255.0/24"
  network_interface_id   = local.vpn_network_interface_id
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

#------------------------------------------------------------------------------
# Private Route Table 1 (us-west-2a)
#------------------------------------------------------------------------------

resource "aws_route_table" "private1" {
  vpc_id = aws_vpc.private_infra.id

  tags = merge(local.common_tags, {
    Name = "private-infra-rtb-private1-us-west-2a"
  })
}

resource "aws_route_table_association" "private1" {
  subnet_id      = aws_subnet.private1.id
  route_table_id = aws_route_table.private1.id
}

#------------------------------------------------------------------------------
# Private Route Table 2 (us-west-2b)
#------------------------------------------------------------------------------

resource "aws_route_table" "private2" {
  vpc_id = aws_vpc.private_infra.id

  tags = merge(local.common_tags, {
    Name = "private-infra-rtb-private2-us-west-2b"
  })
}

resource "aws_route_table_association" "private2" {
  subnet_id      = aws_subnet.private2.id
  route_table_id = aws_route_table.private2.id
}
