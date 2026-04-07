#!/bin/bash
# Import script for route53 module
# Run this after terraform init to import existing AWS resources

set -e

echo "=== Importing Route53 Resources ==="
echo ""

#------------------------------------------------------------------------------
# Hosted Zones
#------------------------------------------------------------------------------
echo "Importing hosted zones..."
terraform import aws_route53_zone.etherport Z03500581XDWV5SKF5PK8
terraform import aws_route53_zone.grahamsmith Z00934751492QCH0VBIQX

#------------------------------------------------------------------------------
# etherport.net Records
#------------------------------------------------------------------------------
echo ""
echo "Importing etherport.net records..."

# Infrastructure
terraform import aws_route53_record.etherport_vpn Z03500581XDWV5SKF5PK8_vpn.etherport.net_A
terraform import aws_route53_record.etherport_wind_wildcard 'Z03500581XDWV5SKF5PK8_*.wind.etherport.net_A'
terraform import aws_route53_record.etherport_ha_wind Z03500581XDWV5SKF5PK8_ha.wind.etherport.net_A

# Email
terraform import aws_route53_record.etherport_dmarc Z03500581XDWV5SKF5PK8__dmarc.etherport.net_TXT
terraform import aws_route53_record.etherport_mail_mx Z03500581XDWV5SKF5PK8_mail.etherport.net_MX
terraform import aws_route53_record.etherport_mail_spf Z03500581XDWV5SKF5PK8_mail.etherport.net_TXT
terraform import aws_route53_record.etherport_dkim_1 Z03500581XDWV5SKF5PK8_5gniifohq7dsyc2lphgcnx4j3a74ofco._domainkey.etherport.net_CNAME
terraform import aws_route53_record.etherport_dkim_2 Z03500581XDWV5SKF5PK8_dy5wbhsewzcikzt45twscs2dl4g4vma2._domainkey.etherport.net_CNAME
terraform import aws_route53_record.etherport_dkim_3 Z03500581XDWV5SKF5PK8_j5gqverli76qyzmlg6ulzs2ey36w6rgb._domainkey.etherport.net_CNAME

#------------------------------------------------------------------------------
# grahamsmith.net Records
#------------------------------------------------------------------------------
echo ""
echo "Importing grahamsmith.net records..."

# Email
terraform import aws_route53_record.grahamsmith_mx Z00934751492QCH0VBIQX_grahamsmith.net_MX
terraform import aws_route53_record.grahamsmith_spf Z00934751492QCH0VBIQX_grahamsmith.net_TXT
terraform import aws_route53_record.grahamsmith_ses_verification Z00934751492QCH0VBIQX__amazonses.grahamsmith.net_TXT
terraform import aws_route53_record.grahamsmith_dmarc Z00934751492QCH0VBIQX__dmarc.grahamsmith.net_TXT
terraform import aws_route53_record.grahamsmith_dkim_1 Z00934751492QCH0VBIQX_345d4ydpdtelkytksyw7wvzuctho5nus._domainkey.grahamsmith.net_CNAME
terraform import aws_route53_record.grahamsmith_dkim_2 Z00934751492QCH0VBIQX_637qs2t6wu5i4n5na7dnsf5j5p2ufhao._domainkey.grahamsmith.net_CNAME
terraform import aws_route53_record.grahamsmith_dkim_3 Z00934751492QCH0VBIQX_wrdadq56jdbha57jnrveghemnjco2y5b._domainkey.grahamsmith.net_CNAME
terraform import aws_route53_record.grahamsmith_autodiscover Z00934751492QCH0VBIQX_autodiscover.grahamsmith.net_CNAME
terraform import aws_route53_record.grahamsmith_mail_mx Z00934751492QCH0VBIQX_mail.grahamsmith.net_MX
terraform import aws_route53_record.grahamsmith_mail_spf Z00934751492QCH0VBIQX_mail.grahamsmith.net_TXT

echo ""
echo "=== Import Complete ==="
echo ""
echo "Next steps:"
echo "1. Run 'terraform plan' to verify state matches configuration"
echo "2. If there are differences, adjust the Terraform config to match"
echo "3. Run 'terraform apply' to finalize"
