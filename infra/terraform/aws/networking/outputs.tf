# Outputs for networking module

#------------------------------------------------------------------------------
# VPC
#------------------------------------------------------------------------------

output "vpc_id" {
  description = "ID of the private-infra VPC"
  value       = aws_vpc.private_infra.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.private_infra.cidr_block
}

output "vpc_ipv6_cidr" {
  description = "IPv6 CIDR block of the VPC"
  value       = aws_vpc.private_infra.ipv6_cidr_block
}

#------------------------------------------------------------------------------
# Subnets
#------------------------------------------------------------------------------

output "subnet_public1_id" {
  description = "ID of public subnet 1 (us-west-2a)"
  value       = aws_subnet.public1.id
}

output "subnet_public2_id" {
  description = "ID of public subnet 2 (us-west-2b)"
  value       = aws_subnet.public2.id
}

output "subnet_private1_id" {
  description = "ID of private subnet 1 (us-west-2a)"
  value       = aws_subnet.private1.id
}

output "subnet_private2_id" {
  description = "ID of private subnet 2 (us-west-2b)"
  value       = aws_subnet.private2.id
}

output "public_subnet_ids" {
  description = "List of public subnet IDs"
  value       = [aws_subnet.public1.id, aws_subnet.public2.id]
}

output "private_subnet_ids" {
  description = "List of private subnet IDs"
  value       = [aws_subnet.private1.id, aws_subnet.private2.id]
}

#------------------------------------------------------------------------------
# Internet Gateway
#------------------------------------------------------------------------------

output "internet_gateway_id" {
  description = "ID of the Internet Gateway"
  value       = aws_internet_gateway.main.id
}

#------------------------------------------------------------------------------
# Security Groups
#------------------------------------------------------------------------------

output "security_group_vpn_id" {
  description = "ID of the VPN server security group"
  value       = aws_security_group.vpn_server.id
}

output "security_group_alb_id" {
  description = "ID of the ALB public HTTPS security group"
  value       = aws_security_group.alb_public.id
}

output "security_group_internal_id" {
  description = "ID of the internal communications security group"
  value       = aws_security_group.internal_comms.id
}

output "security_group_ssh_id" {
  description = "ID of the SSH access security group"
  value       = aws_security_group.allow_ssh.id
}

output "security_group_dns_id" {
  description = "ID of the DNS server security group"
  value       = aws_security_group.dns_server.id
}

#------------------------------------------------------------------------------
# VPC Endpoint
#------------------------------------------------------------------------------

output "vpc_endpoint_s3_id" {
  description = "ID of the S3 VPC endpoint"
  value       = aws_vpc_endpoint.s3.id
}
