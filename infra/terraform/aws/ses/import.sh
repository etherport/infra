#!/bin/bash
# Import script for ses module
# Run this after terraform init to import existing AWS resources

set -e

echo "=== Importing SES Identities ==="
echo ""

# Domain identities
echo "Importing domain identities..."
terraform import aws_ses_domain_identity.etherport etherport.net
terraform import aws_ses_domain_dkim.etherport etherport.net
terraform import aws_ses_domain_identity.grahamsmith grahamsmith.net
terraform import aws_ses_domain_dkim.grahamsmith grahamsmith.net

# Email identities
echo ""
echo "Importing email identities..."
terraform import aws_ses_email_identity.g_grahamsmith g@grahamsmith.net
terraform import aws_ses_email_identity.grahamsm_gmail grahamsm@gmail.com
terraform import aws_ses_email_identity.graham_icloud graham.m.smith@me.com

echo ""
echo "=== Import Complete ==="
echo ""
echo "Next steps:"
echo "1. Run 'terraform plan' to verify state matches configuration"
echo "2. If there are differences, adjust the Terraform config to match"
echo "3. Run 'terraform apply' to finalize"
