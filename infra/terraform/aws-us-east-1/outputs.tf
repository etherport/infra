# AWS US-East-1 Hub Infrastructure
# Outputs

#------------------------------------------------------------------------------
# VPC
#------------------------------------------------------------------------------

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = aws_vpc.main.cidr_block
}

#------------------------------------------------------------------------------
# Subnets
#------------------------------------------------------------------------------

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value = [
    aws_subnet.public1.id,
    aws_subnet.public2.id,
  ]
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value = [
    aws_subnet.private1.id,
    aws_subnet.private2.id,
  ]
}

#------------------------------------------------------------------------------
# VPN Instance
#------------------------------------------------------------------------------

output "vpn_instance_id" {
  description = "VPN EC2 instance ID"
  value       = aws_instance.vpn.id
}

output "vpn_elastic_ip" {
  description = "VPN server Elastic IP"
  value       = aws_eip.vpn.public_ip
}

output "vpn_private_ip" {
  description = "VPN server private IP within VPC"
  value       = aws_instance.vpn.private_ip
}

output "ssh_command" {
  description = "SSH command to connect"
  value       = "ssh -i ~/.ssh/gs-ec2.pem ubuntu@${aws_eip.vpn.public_ip}"
}

#------------------------------------------------------------------------------
# VPC Peering
#------------------------------------------------------------------------------

output "vpc_peering_id" {
  description = "VPC peering connection ID to us-west-2 hub"
  value       = aws_vpc_peering_connection.to_hub.id
}

#------------------------------------------------------------------------------
# WireGuard Configuration
#------------------------------------------------------------------------------

output "wireguard_endpoint" {
  description = "WireGuard endpoint for client config"
  value       = "${aws_eip.vpn.public_ip}:51821"
}

output "homelab_peer_config" {
  description = "Add this peer to homelab's wireguard deployment"
  value       = <<-EOT

    === Add to homelab wireguard 03-deployment.yaml ===

    [Peer]
    # vpn-use1 (us-east-1)
    PublicKey = <wg0_public_key from SOPS>
    Endpoint = ${aws_eip.vpn.public_ip}:51820
    AllowedIPs = ${var.vpc_cidr}, ${var.wg0_tunnel_ip}/32
    PersistentKeepalive = 25

  EOT
}

output "client_config" {
  description = "WireGuard client configuration"
  sensitive   = true
  value       = <<-EOT
    # Save as ~/.wireguard/us-east-1.conf
    #
    # DNS: Using dns-aws (10.10.100.5) which can resolve internal names

    [Interface]
    PrivateKey = <your private key from 1Password>
    Address = 10.254.0.10/32
    DNS = 10.10.100.5, 1.1.1.1

    [Peer]
    # vpn-use1 (us-east-1)
    PublicKey = ${data.sops_file.wg1_keys.data["stringData.wg1_public_key"]}
    Endpoint = ${aws_eip.vpn.public_ip}:51821
    AllowedIPs = 0.0.0.0/0
    PersistentKeepalive = 25
  EOT
}

output "traffic_flow" {
  description = "Traffic routing explanation"
  value       = <<-EOT

    === Traffic Flow ===

    Your Device (10.254.0.10)
         │
         │ WireGuard wg1
         ▼
    vpn-use1 (us-east-1) [${aws_eip.vpn.public_ip}]
         │
         ├── Internet → NAT → Elastic IP (east coast egress)
         │
         ├── AWS us-west-2 (10.10.100.0/22) → VPC Peering → us-west-2
         │
         └── Homelab (10.10.192.0/19) → wg0 tunnel → homelab

    Note: Homelab traffic uses direct wg0 tunnel because VPC peering
    doesn't support transit routing through vpn-aws.

  EOT
}

#------------------------------------------------------------------------------
# Security Groups
#------------------------------------------------------------------------------

output "vpn_security_group_id" {
  description = "VPN server security group ID"
  value       = aws_security_group.vpn_server.id
}

output "internal_comms_security_group_id" {
  description = "Internal communications security group ID"
  value       = aws_security_group.internal_comms.id
}

output "allow_ssh_security_group_id" {
  description = "SSH access security group ID"
  value       = aws_security_group.allow_ssh.id
}
