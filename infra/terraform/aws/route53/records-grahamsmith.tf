# DNS Records for grahamsmith.net
#
# Record categories:
# - Email: MX, SPF, DKIM, DMARC records for SES/WorkMail
# - Infrastructure: Static records
# - Validation: ACM certificate validation records

#------------------------------------------------------------------------------
# Email Records (SES/WorkMail)
#------------------------------------------------------------------------------

# Root MX record - SES inbound
resource "aws_route53_record" "grahamsmith_mx" {
  zone_id = aws_route53_zone.grahamsmith.zone_id
  name    = "grahamsmith.net"
  type    = "MX"
  ttl     = 600
  records = ["10 inbound-smtp.us-west-2.amazonaws.com."]
}

# Root SPF record
resource "aws_route53_record" "grahamsmith_spf" {
  zone_id = aws_route53_zone.grahamsmith.zone_id
  name    = "grahamsmith.net"
  type    = "TXT"
  ttl     = 300
  records = ["v=spf1 include:amazonses.com ~all"]
}

# SES domain verification
resource "aws_route53_record" "grahamsmith_ses_verification" {
  zone_id = aws_route53_zone.grahamsmith.zone_id
  name    = "_amazonses.grahamsmith.net"
  type    = "TXT"
  ttl     = 600
  records = ["YxfS57XyZukjaILeiPOHCr3qnLHK5s9bVQ+pD/PnRZ4="]
}

# DMARC policy
resource "aws_route53_record" "grahamsmith_dmarc" {
  zone_id = aws_route53_zone.grahamsmith.zone_id
  name    = "_dmarc.grahamsmith.net"
  type    = "TXT"
  ttl     = 300
  records = ["v=DMARC1; p=none;"]
}

# SES DKIM records
resource "aws_route53_record" "grahamsmith_dkim_1" {
  zone_id = aws_route53_zone.grahamsmith.zone_id
  name    = "345d4ydpdtelkytksyw7wvzuctho5nus._domainkey.grahamsmith.net"
  type    = "CNAME"
  ttl     = 1800
  records = ["345d4ydpdtelkytksyw7wvzuctho5nus.dkim.amazonses.com"]
}

resource "aws_route53_record" "grahamsmith_dkim_2" {
  zone_id = aws_route53_zone.grahamsmith.zone_id
  name    = "637qs2t6wu5i4n5na7dnsf5j5p2ufhao._domainkey.grahamsmith.net"
  type    = "CNAME"
  ttl     = 1800
  records = ["637qs2t6wu5i4n5na7dnsf5j5p2ufhao.dkim.amazonses.com"]
}

resource "aws_route53_record" "grahamsmith_dkim_3" {
  zone_id = aws_route53_zone.grahamsmith.zone_id
  name    = "wrdadq56jdbha57jnrveghemnjco2y5b._domainkey.grahamsmith.net"
  type    = "CNAME"
  ttl     = 1800
  records = ["wrdadq56jdbha57jnrveghemnjco2y5b.dkim.amazonses.com"]
}

# WorkMail autodiscover
resource "aws_route53_record" "grahamsmith_autodiscover" {
  zone_id = aws_route53_zone.grahamsmith.zone_id
  name    = "autodiscover.grahamsmith.net"
  type    = "CNAME"
  ttl     = 600
  records = ["autodiscover.mail.us-west-2.awsapps.com."]
}

# Mail subdomain MX record
resource "aws_route53_record" "grahamsmith_mail_mx" {
  zone_id = aws_route53_zone.grahamsmith.zone_id
  name    = "mail.grahamsmith.net"
  type    = "MX"
  ttl     = 300
  records = ["10 feedback-smtp.us-west-2.amazonses.com"]
}

# Mail subdomain SPF record
resource "aws_route53_record" "grahamsmith_mail_spf" {
  zone_id = aws_route53_zone.grahamsmith.zone_id
  name    = "mail.grahamsmith.net"
  type    = "TXT"
  ttl     = 300
  records = ["v=spf1 include:amazonses.com ~all"]
}

#------------------------------------------------------------------------------
# DDNS Records - Managed by ddns-lambda, NOT imported to Terraform
#------------------------------------------------------------------------------
# The following records are dynamically updated and should NOT be managed
# by Terraform:
#
# - vpn.grahamsmith.net (A) - Dynamic VPN IP
# - windtryst.grahamsmith.net (CNAME) - Points to wind.gmsmeg.net (deprecated)

#------------------------------------------------------------------------------
# ACM Validation Records - Managed separately
#------------------------------------------------------------------------------
# The following records are for ACM certificate validation:
#
# - _4239d363063c3d0cd2e92c546faf363d.grahamsmith.net (CNAME) - *.grahamsmith.net cert
