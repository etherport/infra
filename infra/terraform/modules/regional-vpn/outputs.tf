# Regional VPN Module Outputs

output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.vpn.id
}

output "public_ip" {
  description = "Public IP address (use for WireGuard endpoint)"
  value       = var.use_elastic_ip ? aws_eip.vpn[0].public_ip : aws_instance.vpn.public_ip
}

output "private_ip" {
  description = "Private IP address within VPC"
  value       = aws_instance.vpn.private_ip
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.vpn.id
}

output "security_group_id" {
  description = "Security group ID"
  value       = aws_security_group.vpn.id
}

output "wireguard_client_config" {
  description = "WireGuard client configuration snippet"
  sensitive   = true
  value       = <<-EOT
    # Add this peer to your WireGuard config
    # File: ~/.wireguard/travel-${var.region_short}.conf

    [Interface]
    PrivateKey = <YOUR_PRIVATE_KEY>
    Address = 10.254.0.10/32
    DNS = 10.10.201.5

    [Peer]
    # vpn-${var.region_short}
    PublicKey = <SERVER_PUBLIC_KEY>
    Endpoint = ${var.use_elastic_ip ? aws_eip.vpn[0].public_ip : aws_instance.vpn.public_ip}:51821
    AllowedIPs = 0.0.0.0/0
    PersistentKeepalive = 25
  EOT
}

output "ssh_command" {
  description = "SSH command to connect to instance"
  value       = "ssh -i ~/.ssh/gs-ec2.pem ubuntu@${var.use_elastic_ip ? aws_eip.vpn[0].public_ip : aws_instance.vpn.public_ip}"
}

output "estimated_cost" {
  description = "Estimated monthly cost"
  value       = "~$3.07/month (t4g.nano) + data transfer"
}

output "dns_record_fqdn" {
  description = "FQDN of the Route53 A record created for this VPN endpoint (empty if not created)"
  value       = length(aws_route53_record.vpn_endpoint) > 0 ? aws_route53_record.vpn_endpoint[0].fqdn : ""
}
