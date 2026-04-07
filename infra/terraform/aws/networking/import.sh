#!/bin/bash
# Import script for networking module
# Run this after terraform init to import existing AWS resources

set -e

echo "=== Importing AWS Networking Resources ==="
echo ""

# VPC (includes IPv6 CIDR block - managed via assign_generated_ipv6_cidr_block)
echo "Importing VPC..."
terraform import aws_vpc.private_infra vpc-0cf7cb3b71fc48958

# Subnets
echo "Importing subnets..."
terraform import aws_subnet.public1 subnet-05df0a901053021dd
terraform import aws_subnet.public2 subnet-08263b4042c6e3b03
terraform import aws_subnet.private1 subnet-0578f069a3ceff73d
terraform import aws_subnet.private2 subnet-0f0b317cb9a0c0c33

# Internet Gateway
echo "Importing Internet Gateway..."
terraform import aws_internet_gateway.main igw-0a16bb3b222de5050

# VPC Endpoint (S3)
echo "Importing VPC Endpoint..."
terraform import aws_vpc_endpoint.s3 vpce-02628c8867301ebb6

# Route Tables
echo "Importing route tables..."
terraform import aws_route_table.main rtb-06f6c606f6702d44a
terraform import aws_route_table.public rtb-061bae65fde0129bb
terraform import aws_route_table.private1 rtb-00dfb5365f007df90
terraform import aws_route_table.private2 rtb-0b19708e320e52614

# Note: Main route table association cannot be imported (AWS/Terraform limitation)
# The VPC's main route table is implicitly associated

# Route Table Associations
echo "Importing route table associations..."
terraform import aws_route_table_association.public1 subnet-05df0a901053021dd/rtb-061bae65fde0129bb
terraform import aws_route_table_association.public2 subnet-08263b4042c6e3b03/rtb-061bae65fde0129bb
terraform import aws_route_table_association.private1 subnet-0578f069a3ceff73d/rtb-00dfb5365f007df90
terraform import aws_route_table_association.private2 subnet-0f0b317cb9a0c0c33/rtb-0b19708e320e52614

# Routes in public route table
echo "Importing routes..."
terraform import aws_route.public_internet_ipv4 rtb-061bae65fde0129bb_0.0.0.0/0
terraform import aws_route.public_internet_ipv6 rtb-061bae65fde0129bb_::/0
terraform import aws_route.public_to_homelab rtb-061bae65fde0129bb_10.10.192.0/19
terraform import aws_route.public_to_vpn_clients rtb-061bae65fde0129bb_10.254.0.0/24
terraform import aws_route.public_to_s2s_vpn rtb-061bae65fde0129bb_10.255.255.0/24

# Default Network ACL
echo "Importing Network ACL..."
terraform import aws_default_network_acl.main acl-0282c4f7529cdf112

# Security Groups
echo "Importing security groups..."
terraform import aws_default_security_group.default sg-08c618f67c2ec61d4
terraform import aws_security_group.vpn_server sg-08323ff8e98ecb563
terraform import aws_security_group.alb_public sg-0a4bebabcd3bd4d20
terraform import aws_security_group.internal_comms sg-0c882ffea5692bd63
terraform import aws_security_group.allow_ssh sg-0079fee23ee54417a
terraform import aws_security_group.dns_server sg-08d12e417159c18d2

# Security Group Rules
echo "Importing security group rules..."

# VPN Server rules
terraform import aws_vpc_security_group_ingress_rule.vpn_wireguard sgr-023f6e5eafca0ec04
terraform import aws_vpc_security_group_egress_rule.vpn_all_ipv4 sgr-09536fd6dcd3fd651
terraform import aws_vpc_security_group_egress_rule.vpn_all_ipv6 sgr-0a3b888332fde603e

# ALB Public rules
terraform import aws_vpc_security_group_ingress_rule.alb_https sgr-0a0a8e38cd4156909
terraform import aws_vpc_security_group_egress_rule.alb_all_ipv4 sgr-0e4943e2f114eb8be
terraform import aws_vpc_security_group_egress_rule.alb_all_ipv6 sgr-091451e4f836b889e

# Internal Comms rules
terraform import aws_vpc_security_group_ingress_rule.internal_vpc sgr-085ca120095c65a1a
terraform import aws_vpc_security_group_ingress_rule.internal_homelab sgr-0922a2d1eaa561790
terraform import aws_vpc_security_group_ingress_rule.internal_vpn_clients sgr-09ba2fa6a24c536c6
terraform import aws_vpc_security_group_ingress_rule.internal_s2s_vpn sgr-0a7a53588b408a74a
terraform import aws_vpc_security_group_egress_rule.internal_all_ipv4 sgr-0e1a622da6b710202
terraform import aws_vpc_security_group_egress_rule.internal_all_ipv6 sgr-055b368088eff4f83

# Allow SSH rules
terraform import aws_vpc_security_group_ingress_rule.ssh_restricted sgr-0b459a6b686c34f80
terraform import aws_vpc_security_group_egress_rule.ssh_all_ipv4 sgr-0e76b9bd062796770
terraform import aws_vpc_security_group_egress_rule.ssh_all_ipv6 sgr-030eebbac35ec9fda

# DNS Server rules
terraform import aws_vpc_security_group_ingress_rule.dns_udp_homelab1 sgr-094a9e883e549baef
terraform import aws_vpc_security_group_ingress_rule.dns_udp_homelab2 sgr-0d7211a384ef45017
terraform import aws_vpc_security_group_ingress_rule.dns_tcp_homelab1 sgr-069df6e4b346d9ea0
terraform import aws_vpc_security_group_ingress_rule.dns_tcp_homelab2 sgr-0b075f3bcef77f17b
terraform import aws_vpc_security_group_ingress_rule.dns_https_cloudfront sgr-0a4e058302a2ba5dd
terraform import aws_vpc_security_group_egress_rule.dns_all_ipv4 sgr-02e9d90d1bc29da63
terraform import aws_vpc_security_group_egress_rule.dns_all_ipv6 sgr-069acea456702763d

echo ""
echo "=== Import Complete ==="
echo ""
echo "Next steps:"
echo "1. Run 'terraform plan' to verify no changes are needed"
echo "2. If there are tag differences, run 'terraform apply' to add module tags"
echo "3. Repeat until 'terraform plan' shows no changes"
