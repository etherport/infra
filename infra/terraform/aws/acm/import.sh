#!/bin/bash
# Import script for acm module
# Run this after terraform init to import existing AWS resources

set -e

echo "=== Importing ACM Certificates ==="
echo ""

# *.grahamsmith.net
echo "Importing *.grahamsmith.net certificate..."
terraform import aws_acm_certificate.grahamsmith_wildcard arn:aws:acm:us-west-2:830881980142:certificate/bdc9a820-fc67-49ad-98ec-ee18652fe70a

# *.etherport.net
echo "Importing *.etherport.net certificate..."
terraform import aws_acm_certificate.etherport_wildcard arn:aws:acm:us-west-2:830881980142:certificate/aecdf0d6-c589-4a9b-bedb-2f5452a953ea

# *.wind.etherport.net
echo "Importing *.wind.etherport.net certificate..."
terraform import aws_acm_certificate.wind_etherport_wildcard arn:aws:acm:us-west-2:830881980142:certificate/dec3f53a-98d2-406d-a182-2e4c383d3b84

# ha.wind.etherport.net
echo "Importing ha.wind.etherport.net certificate..."
terraform import aws_acm_certificate.ha_wind_etherport arn:aws:acm:us-west-2:830881980142:certificate/dd55e262-1185-46c0-be3b-8430c709f068

echo ""
echo "=== Import Complete ==="
echo ""
echo "Next steps:"
echo "1. Run 'terraform plan' to verify state matches configuration"
echo "2. If there are differences, adjust the Terraform config to match"
echo "3. Run 'terraform apply' to finalize"
