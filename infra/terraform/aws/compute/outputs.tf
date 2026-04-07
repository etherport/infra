# Outputs for compute module

#------------------------------------------------------------------------------
# EC2 Instances
#------------------------------------------------------------------------------

output "vpn_instance_id" {
  description = "ID of the VPN EC2 instance"
  value       = aws_instance.vpn.id
}

output "vpn_private_ip" {
  description = "Private IP of the VPN instance"
  value       = aws_instance.vpn.private_ip
}

output "vpn_public_ip" {
  description = "Public IP (EIP) of the VPN instance"
  value       = aws_eip.vpn.public_ip
}

output "dns_instance_id" {
  description = "ID of the DNS EC2 instance"
  value       = aws_instance.dns.id
}

output "dns_private_ip" {
  description = "Private IP of the DNS instance"
  value       = aws_instance.dns.private_ip
}

output "dns_public_ip" {
  description = "Public IP (EIP) of the DNS instance"
  value       = aws_eip.dns.public_ip
}

#------------------------------------------------------------------------------
# Network Interfaces (for routing references)
#------------------------------------------------------------------------------

output "vpn_network_interface_id" {
  description = "Network interface ID of the VPN instance (used for VPC routes)"
  value       = aws_instance.vpn.primary_network_interface_id
}

#------------------------------------------------------------------------------
# IAM
#------------------------------------------------------------------------------

output "instance_profile_name" {
  description = "Name of the EC2 instance profile"
  value       = aws_iam_instance_profile.ec2_cloudwatch_agent.name
}

output "instance_profile_arn" {
  description = "ARN of the EC2 instance profile"
  value       = aws_iam_instance_profile.ec2_cloudwatch_agent.arn
}

#------------------------------------------------------------------------------
# DLM (Managed outside Terraform - uses SIMPLIFIED policy format)
#------------------------------------------------------------------------------

output "dlm_policy_id" {
  description = "ID of the DLM lifecycle policy (managed outside Terraform)"
  value       = "policy-00301f06dbf98ab54"
}

#------------------------------------------------------------------------------
# SNS
#------------------------------------------------------------------------------

output "sns_topic_arn" {
  description = "ARN of the EC2 alerts SNS topic"
  value       = aws_sns_topic.ec2_alerts.arn
}
