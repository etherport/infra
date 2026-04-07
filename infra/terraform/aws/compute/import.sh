#!/bin/bash
# Import script for compute module
# Run this after terraform init to import existing AWS resources

set -e

echo "=== Importing AWS Compute Resources ==="
echo ""

# IAM Role and Instance Profile
echo "Importing IAM resources..."
terraform import aws_iam_role.ec2_cloudwatch_agent ec2-cloudwatch-agent
terraform import aws_iam_instance_profile.ec2_cloudwatch_agent ec2-cloudwatch-agent

# Key Pair (note: public key not retrievable after creation)
echo "Importing key pair..."
terraform import aws_key_pair.gs_ec2 GS-EC2

# EC2 Instances
echo "Importing EC2 instances..."
terraform import aws_instance.vpn i-0f81ff99edc6ede03
terraform import aws_instance.dns i-0c49c3c41bd03d618

# Elastic IPs
echo "Importing Elastic IPs..."
terraform import aws_eip.vpn eipalloc-0a04cc1604b2bb40a
terraform import aws_eip.dns eipalloc-0fac13fcb1f04e7be

# NOTE: DLM Policy (policy-00301f06dbf98ab54) is NOT managed by Terraform
# It uses AWS's SIMPLIFIED policy format which the provider doesn't support

# SNS Topic
echo "Importing SNS topic..."
terraform import aws_sns_topic.ec2_alerts arn:aws:sns:us-west-2:830881980142:CloudWatch_Alarms_EC2_Low_memory

# SNS Subscription (email subscriptions have specific ARN format)
echo "Importing SNS subscription..."
terraform import aws_sns_topic_subscription.ec2_alerts_email arn:aws:sns:us-west-2:830881980142:CloudWatch_Alarms_EC2_Low_memory:60548df5-7bdf-4ea3-9b9e-0d1355c9457d

# CloudWatch Alarms
echo "Importing CloudWatch alarms..."
terraform import aws_cloudwatch_metric_alarm.vpn_high_memory High-Memory-Utilization-VPN
terraform import aws_cloudwatch_metric_alarm.vpn_high_swap High-Swap-Utilization-VPN
terraform import aws_cloudwatch_metric_alarm.dns_high_memory High-Memory-Utilization-DNS
terraform import aws_cloudwatch_metric_alarm.dns_high_swap High-Swap-Utilization-DNS

echo ""
echo "=== Import Complete ==="
echo ""
echo "Next steps:"
echo "1. Run 'terraform plan' to verify state matches configuration"
echo "2. If there are differences, adjust the Terraform config to match"
echo "3. Run 'terraform apply' to add any missing tags"
