# DNS Records for etherport.net
#
# Record categories:
# - Infrastructure: Static records pointing to AWS resources (EIPs, ALB)
# - Email: MX, SPF, DKIM, DMARC records for SES
# - DDNS: Dynamic records updated by ddns-lambda (excluded from Terraform)
# - Validation: ACM certificate validation records (managed by ACM module)

#------------------------------------------------------------------------------
# Infrastructure Records
#------------------------------------------------------------------------------

# ALB alias for *.wind.etherport.net
resource "aws_route53_record" "etherport_wind_wildcard" {
  zone_id = aws_route53_zone.etherport.zone_id
  name    = "*.wind.etherport.net"
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

# ALB alias for ha.wind.etherport.net
resource "aws_route53_record" "etherport_ha_wind" {
  zone_id = aws_route53_zone.etherport.zone_id
  name    = "ha.wind.etherport.net"
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

#------------------------------------------------------------------------------
# Email Records (SES)
#------------------------------------------------------------------------------

# DMARC policy
resource "aws_route53_record" "etherport_dmarc" {
  zone_id = aws_route53_zone.etherport.zone_id
  name    = "_dmarc.etherport.net"
  type    = "TXT"
  ttl     = 300
  records = ["v=DMARC1; p=none;"]
}

# Mail subdomain MX record
resource "aws_route53_record" "etherport_mail_mx" {
  zone_id = aws_route53_zone.etherport.zone_id
  name    = "mail.etherport.net"
  type    = "MX"
  ttl     = 300
  records = ["10 feedback-smtp.us-west-2.amazonses.com"]
}

# Mail subdomain SPF record
resource "aws_route53_record" "etherport_mail_spf" {
  zone_id = aws_route53_zone.etherport.zone_id
  name    = "mail.etherport.net"
  type    = "TXT"
  ttl     = 300
  records = ["v=spf1 include:amazonses.com ~all"]
}

# SES DKIM records
resource "aws_route53_record" "etherport_dkim_1" {
  zone_id = aws_route53_zone.etherport.zone_id
  name    = "5gniifohq7dsyc2lphgcnx4j3a74ofco._domainkey.etherport.net"
  type    = "CNAME"
  ttl     = 1800
  records = ["5gniifohq7dsyc2lphgcnx4j3a74ofco.dkim.amazonses.com"]
}

resource "aws_route53_record" "etherport_dkim_2" {
  zone_id = aws_route53_zone.etherport.zone_id
  name    = "dy5wbhsewzcikzt45twscs2dl4g4vma2._domainkey.etherport.net"
  type    = "CNAME"
  ttl     = 1800
  records = ["dy5wbhsewzcikzt45twscs2dl4g4vma2.dkim.amazonses.com"]
}

resource "aws_route53_record" "etherport_dkim_3" {
  zone_id = aws_route53_zone.etherport.zone_id
  name    = "j5gqverli76qyzmlg6ulzs2ey36w6rgb._domainkey.etherport.net"
  type    = "CNAME"
  ttl     = 1800
  records = ["j5gqverli76qyzmlg6ulzs2ey36w6rgb.dkim.amazonses.com"]
}

#------------------------------------------------------------------------------
# DDNS Records - Managed by ddns-lambda, NOT imported to Terraform
#------------------------------------------------------------------------------
# The following records are dynamically updated by the ddns-lambda function
# and should NOT be managed by Terraform:
#
# - wan1.etherport.net (A) - Home WAN IP 1
# - wan2.etherport.net (A) - Home WAN IP 2
# - wind.etherport.net (A) - Home primary IP
# - wan1.wind.etherport.net (A) - Wind WAN IP 1
# - wan2.wind.etherport.net (A) - Wind WAN IP 2
# - _acme-challenge.wind.etherport.net (TXT) - Let's Encrypt challenges

#------------------------------------------------------------------------------
# ACM Validation Records - Managed separately
#------------------------------------------------------------------------------
# The following records are for ACM certificate validation and will be
# managed by the ACM module:
#
# - _f6abe49fcaf7ee83c8013566f97ee85a.etherport.net (CNAME) - *.etherport.net cert
# - _8e381876b8967e8fa6ba2c810f7c420c.wind.etherport.net (CNAME) - *.wind.etherport.net cert
# - _1ccc76b4b2b06ff626fc1c649b61ab26.ha.wind.etherport.net (CNAME) - ha.wind.etherport.net cert
