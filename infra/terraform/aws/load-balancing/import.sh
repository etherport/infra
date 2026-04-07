#!/bin/bash
# Import script for load-balancing module
# Run this after terraform init to import existing AWS resources

set -e

echo "=== Importing AWS Load Balancing Resources ==="
echo ""

# Application Load Balancer
echo "Importing ALB..."
terraform import aws_lb.main arn:aws:elasticloadbalancing:us-west-2:830881980142:loadbalancer/app/private-infra-alb/b80aa78d7562bac7

# Target Group
echo "Importing target group..."
terraform import aws_lb_target_group.traefik arn:aws:elasticloadbalancing:us-west-2:830881980142:targetgroup/traefik-wind-etherport-net/4d57b4fab3697a62

# Target Group Attachment (IP target)
echo "Importing target group attachment..."
terraform import aws_lb_target_group_attachment.traefik "arn:aws:elasticloadbalancing:us-west-2:830881980142:targetgroup/traefik-wind-etherport-net/4d57b4fab3697a62 10.10.201.70 443"

# HTTPS Listener
echo "Importing HTTPS listener..."
terraform import aws_lb_listener.https arn:aws:elasticloadbalancing:us-west-2:830881980142:listener/app/private-infra-alb/b80aa78d7562bac7/ef585000d769b8ce

# Listener Certificates (SNI)
echo "Importing listener certificates..."
terraform import aws_lb_listener_certificate.etherport_wildcard "arn:aws:elasticloadbalancing:us-west-2:830881980142:listener/app/private-infra-alb/b80aa78d7562bac7/ef585000d769b8ce_arn:aws:acm:us-west-2:830881980142:certificate/aecdf0d6-c589-4a9b-bedb-2f5452a953ea"
terraform import aws_lb_listener_certificate.wind_etherport_wildcard "arn:aws:elasticloadbalancing:us-west-2:830881980142:listener/app/private-infra-alb/b80aa78d7562bac7/ef585000d769b8ce_arn:aws:acm:us-west-2:830881980142:certificate/dec3f53a-98d2-406d-a182-2e4c383d3b84"
terraform import aws_lb_listener_certificate.ha_wind_etherport "arn:aws:elasticloadbalancing:us-west-2:830881980142:listener/app/private-infra-alb/b80aa78d7562bac7/ef585000d769b8ce_arn:aws:acm:us-west-2:830881980142:certificate/dd55e262-1185-46c0-be3b-8430c709f068"

# Listener Rules
echo "Importing listener rules..."
terraform import aws_lb_listener_rule.wind_etherport_services arn:aws:elasticloadbalancing:us-west-2:830881980142:listener-rule/app/private-infra-alb/b80aa78d7562bac7/ef585000d769b8ce/d1ed8dde20f041f6

echo ""
echo "=== Import Complete ==="
echo ""
echo "Next steps:"
echo "1. Run 'terraform plan' to verify state matches configuration"
echo "2. If there are differences, adjust the Terraform config to match"
echo "3. Remove gmsmeg.net certificates from listener"
echo "4. Run 'terraform apply' to finalize"
