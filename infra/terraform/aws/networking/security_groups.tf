# Security Groups for private-infra VPC

#------------------------------------------------------------------------------
# Locals
#------------------------------------------------------------------------------

# AWS-managed prefix list IDs (these are constant per region)
locals {
  # CloudFront origin-facing prefix list (for allowing CloudFront to reach origins)
  cloudfront_prefix_list_id = "pl-82a045eb"
}

#------------------------------------------------------------------------------
# Default Security Group
#------------------------------------------------------------------------------

resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.private_infra.id

  tags = merge(local.common_tags, {
    Name = "private-infra-default-sg"
  })
}

#------------------------------------------------------------------------------
# VPN Server Security Group
#------------------------------------------------------------------------------

resource "aws_security_group" "vpn_server" {
  name        = "vpn-server_sg"
  description = "Allow access to public and private VPN resources"
  vpc_id      = aws_vpc.private_infra.id

  tags = merge(local.common_tags, {
    Name = "vpn-server_sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "vpn_wireguard" {
  security_group_id = aws_security_group.vpn_server.id
  description       = "Public WireGuard VPN access"
  ip_protocol       = "udp"
  from_port         = 51820
  to_port           = 51821
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "vpn_wstunnel" {
  security_group_id = aws_security_group.vpn_server.id
  description       = "wstunnel WSS for WireGuard over TCP (restrictive networks)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
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

#------------------------------------------------------------------------------
# ALB Public HTTPS Security Group
#------------------------------------------------------------------------------

resource "aws_security_group" "alb_public" {
  name        = "private-infra_alb-public-443"
  description = "Allow HTTPS for ALB"
  vpc_id      = aws_vpc.private_infra.id

  tags = merge(local.common_tags, {
    Name = "private-infra_alb-public-443"
  })
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb_public.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_all_ipv4" {
  security_group_id = aws_security_group.alb_public.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_all_ipv6" {
  security_group_id = aws_security_group.alb_public.id
  ip_protocol       = "-1"
  cidr_ipv6         = "::/0"
}

#------------------------------------------------------------------------------
# Internal Communications Security Group
#------------------------------------------------------------------------------

resource "aws_security_group" "internal_comms" {
  name        = "private-infra-internal-comms_sg"
  description = "Allow private communications within subnet"
  vpc_id      = aws_vpc.private_infra.id

  tags = merge(local.common_tags, {
    Name = "private-infra-internal-comms_sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "internal_vpc" {
  security_group_id = aws_security_group.internal_comms.id
  description       = "Allow all traffic from other vpc resources"
  ip_protocol       = "-1"
  cidr_ipv4         = "10.10.100.0/22"
}

resource "aws_vpc_security_group_ingress_rule" "internal_homelab" {
  security_group_id = aws_security_group.internal_comms.id
  description       = "Allow all traffic from wind network"
  ip_protocol       = "-1"
  cidr_ipv4         = "10.10.192.0/19"
}

resource "aws_vpc_security_group_ingress_rule" "internal_aws_spokes" {
  security_group_id = aws_security_group.internal_comms.id
  description       = "Allow all traffic from AWS spoke VPCs (use1 hub, regional/travel VPNs)"
  ip_protocol       = "-1"
  cidr_ipv4         = "10.10.96.0/19"
}

resource "aws_vpc_security_group_ingress_rule" "internal_vpn_clients" {
  security_group_id = aws_security_group.internal_comms.id
  description       = "Allow all traffic from remote VPN clients"
  ip_protocol       = "-1"
  cidr_ipv4         = "10.254.0.0/24"
}

resource "aws_vpc_security_group_ingress_rule" "internal_s2s_vpn" {
  security_group_id = aws_security_group.internal_comms.id
  description       = "Allow all traffic from S2S VPN tunnel IPs"
  ip_protocol       = "-1"
  cidr_ipv4         = "10.255.255.0/29"
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
# SSH Access Security Group
#------------------------------------------------------------------------------

resource "aws_security_group" "allow_ssh" {
  name        = "allow-ssh_sg"
  description = "Allow SSH access to restricted IP"
  vpc_id      = aws_vpc.private_infra.id

  tags = merge(local.common_tags, {
    Name = "allow-ssh_sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "ssh_restricted" {
  security_group_id = aws_security_group.allow_ssh.id
  description       = "Allow SSH access from homelab WAN"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = var.ssh_allowed_ip
}

resource "aws_vpc_security_group_ingress_rule" "ssh_remote" {
  security_group_id = aws_security_group.allow_ssh.id
  description       = "Allow SSH access from remote location"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = "47.34.215.233/32"
}

resource "aws_vpc_security_group_egress_rule" "ssh_all_ipv4" {
  security_group_id = aws_security_group.allow_ssh.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "ssh_all_ipv6" {
  security_group_id = aws_security_group.allow_ssh.id
  ip_protocol       = "-1"
  cidr_ipv6         = "::/0"
}

#------------------------------------------------------------------------------
# DNS Server Security Group
#------------------------------------------------------------------------------

resource "aws_security_group" "dns_server" {
  name        = "dns-server_sg"
  description = "Allows public DNS requests"
  vpc_id      = aws_vpc.private_infra.id

  tags = merge(local.common_tags, {
    Name = "dns-server_sg"
  })
}

# DNS access from homelab WAN IPs — these four rules are now managed
# by the dns-restrict-ip Lambda (infra/terraform/aws/dns-restrict-ip)
# which keeps them in sync with Route53 records wan1/wan2.wind.etherport.net.
# The Lambda re-applies on every Route53 change so hardcoding the IPs
# here would silently drift on the next IP change.
#
# Removed from this module on 2026-05-23 (H6). The four `removed`
# blocks below tell TF to forget them without destroying — the Lambda
# continues writing to the SG via boto3.
removed {
  from = aws_vpc_security_group_ingress_rule.dns_udp_homelab1
  lifecycle { destroy = false }
}
removed {
  from = aws_vpc_security_group_ingress_rule.dns_udp_homelab2
  lifecycle { destroy = false }
}
removed {
  from = aws_vpc_security_group_ingress_rule.dns_tcp_homelab1
  lifecycle { destroy = false }
}
removed {
  from = aws_vpc_security_group_ingress_rule.dns_tcp_homelab2
  lifecycle { destroy = false }
}

# HTTPS access from CloudFront (for DoH or management)
resource "aws_vpc_security_group_ingress_rule" "dns_https_cloudfront" {
  security_group_id = aws_security_group.dns_server.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  prefix_list_id    = local.cloudfront_prefix_list_id
}

resource "aws_vpc_security_group_egress_rule" "dns_all_ipv4" {
  security_group_id = aws_security_group.dns_server.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "dns_all_ipv6" {
  security_group_id = aws_security_group.dns_server.id
  ip_protocol       = "-1"
  cidr_ipv6         = "::/0"
}
