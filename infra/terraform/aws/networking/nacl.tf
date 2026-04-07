# Network ACL for private-infra VPC
# Custom rules for DNS, HTTPS, VPN, SSH, homelab CIDRs, and ephemeral ports

resource "aws_default_network_acl" "main" {
  default_network_acl_id = aws_vpc.private_infra.default_network_acl_id

  subnet_ids = [
    aws_subnet.public1.id,
    aws_subnet.public2.id,
    aws_subnet.private1.id,
    aws_subnet.private2.id,
  ]

  tags = merge(local.common_tags, {
    Name = "private-infra-nacl-main"
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

  # Allow all outbound IPv6
  egress {
    rule_no         = 101
    protocol        = "-1"
    action          = "allow"
    ipv6_cidr_block = "::/0"
    from_port       = 0
    to_port         = 0
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

  # DNS TCP (IPv6)
  ingress {
    rule_no         = 101
    protocol        = "tcp"
    action          = "allow"
    ipv6_cidr_block = "::/0"
    from_port       = 53
    to_port         = 53
  }

  # DNS UDP (IPv4)
  ingress {
    rule_no    = 102
    protocol   = "udp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 53
    to_port    = 53
  }

  # DNS UDP (IPv6)
  ingress {
    rule_no         = 103
    protocol        = "udp"
    action          = "allow"
    ipv6_cidr_block = "::/0"
    from_port       = 53
    to_port         = 53
  }

  # HTTPS (IPv4)
  ingress {
    rule_no    = 104
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 443
    to_port    = 443
  }

  # HTTPS (IPv6)
  ingress {
    rule_no         = 105
    protocol        = "tcp"
    action          = "allow"
    ipv6_cidr_block = "::/0"
    from_port       = 443
    to_port         = 443
  }

  # VPN/OpenVPN UDP (IPv4)
  ingress {
    rule_no    = 106
    protocol   = "udp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1194
    to_port    = 1195
  }

  # VPN/OpenVPN UDP (IPv6)
  ingress {
    rule_no         = 107
    protocol        = "udp"
    action          = "allow"
    ipv6_cidr_block = "::/0"
    from_port       = 1194
    to_port         = 1195
  }

  # Homelab network (all traffic)
  ingress {
    rule_no    = 108
    protocol   = "-1"
    action     = "allow"
    cidr_block = "10.10.192.0/19"
    from_port  = 0
    to_port    = 0
  }

  # VPN clients 1 (all traffic)
  ingress {
    rule_no    = 109
    protocol   = "-1"
    action     = "allow"
    cidr_block = "10.8.10.0/24"
    from_port  = 0
    to_port    = 0
  }

  # VPN clients 2 (all traffic)
  ingress {
    rule_no    = 110
    protocol   = "-1"
    action     = "allow"
    cidr_block = "10.8.20.0/24"
    from_port  = 0
    to_port    = 0
  }

  # VPC CIDR (all traffic)
  ingress {
    rule_no    = 111
    protocol   = "-1"
    action     = "allow"
    cidr_block = "10.10.100.0/22"
    from_port  = 0
    to_port    = 0
  }

  # SSH (IPv4)
  ingress {
    rule_no    = 112
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 22
    to_port    = 22
  }

  # Ephemeral ports TCP (IPv4)
  ingress {
    rule_no    = 113
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  # Ephemeral ports TCP (IPv6)
  ingress {
    rule_no         = 114
    protocol        = "tcp"
    action          = "allow"
    ipv6_cidr_block = "::/0"
    from_port       = 1024
    to_port         = 65535
  }

  # Ephemeral ports UDP (IPv4)
  ingress {
    rule_no    = 115
    protocol   = "udp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  # Ephemeral ports UDP (IPv6)
  ingress {
    rule_no         = 116
    protocol        = "udp"
    action          = "allow"
    ipv6_cidr_block = "::/0"
    from_port       = 1024
    to_port         = 65535
  }

  # ICMP (IPv4)
  ingress {
    rule_no    = 117
    protocol   = "icmp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    icmp_type  = -1
    icmp_code  = -1
    from_port  = 0
    to_port    = 0
  }

  # ICMPv6 (IPv6)
  ingress {
    rule_no         = 118
    protocol        = "58" # ICMPv6
    action          = "allow"
    ipv6_cidr_block = "::/0"
    icmp_type       = -1
    icmp_code       = -1
    from_port       = 0
    to_port         = 0
  }
}
