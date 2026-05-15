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

# VPN endpoints for remote access (WireGuard)
resource "aws_route53_record" "etherport_vpn_use1" {
  zone_id = aws_route53_zone.etherport.zone_id
  name    = "vpn-use1.etherport.net"
  type    = "A"
  ttl     = 300
  records = [var.vpn_use1_public_ip]
}

resource "aws_route53_record" "etherport_vpn_usw2" {
  zone_id = aws_route53_zone.etherport.zone_id
  name    = "vpn-usw2.etherport.net"
  type    = "A"
  ttl     = 300
  records = [var.vpn_usw2_public_ip]
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

#------------------------------------------------------------------------------
# Internal-only hostname sinkholes
#
# `*.wind.etherport.net` ALIASes to the private-infra ALB by default —
# convenient for public HTTP services (ha, plex, chat) but ALSO catches
# internal-only hostnames like pve.wind.etherport.net (Proxmox admin UI,
# K8s API, etc.) that should NEVER be publicly resolvable.
#
# Two ways to handle this:
#   1. Explicit sinkhole records below — override the wildcard for each
#      internal-only host. Returns 127.0.0.1 publicly; technitium's
#      authoritative wind.etherport.net zone returns the real local IP
#      (split-horizon).
#   2. Remove the wildcard entirely and add explicit records per public
#      service (cleaner but more maintenance — each new public service
#      needs a Route53 change).
#
# Option 1 (this file) is the pragmatic choice for a homelab. The
# `private-infra-alb` already gates listed services via WAF + path
# routing, so a request that hit the ALB with `Host: pve.wind...`
# wouldn't actually reach Proxmox — but defense in depth: don't even
# resolve the name publicly.
#
# 127.0.0.1 is the conventional sinkhole. Externally a curl returns
# "Connection refused" (loopback). Internally, technitium returns the
# real 10.10.200.41 (PVE host).
#------------------------------------------------------------------------------

locals {
  # Internal-only hostnames under wind.etherport.net that should NOT
  # resolve to the public ALB. Add new entries here as you add admin
  # interfaces / Proxmox-tier services.
  internal_only_hosts = [
    "pve",  # Proxmox admin UI (8006)
    "ceph", # Ceph dashboard, if exposed
  ]
}

resource "aws_route53_record" "wind_internal_sinkhole" {
  for_each = toset(local.internal_only_hosts)

  zone_id = aws_route53_zone.etherport.zone_id
  name    = "${each.key}.wind.etherport.net"
  type    = "A"
  ttl     = 300
  records = ["127.0.0.1"]
}
