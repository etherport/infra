# ACM Certificates for homelab infrastructure (us-west-2)
#
# These certificates predate the 2026-05-27 ALB decom. They are
# retained for now (no ongoing cost; cert-manager handles in-cluster
# TLS via Let's Encrypt). Validation records were originally in the
# deleted route53 module — they're now mirrored as CNAME entries in
# infra/terraform/cloudflare/variables.tf under the
# "ACME DNS-01 validation" group so renewals continue to work.
#
# Candidates for deletion once we're confident nothing references
# them: ha_wind_etherport (Home Assistant moved to in-cluster TLS),
# wind_etherport_wildcard (ALB consumer is gone).

#------------------------------------------------------------------------------
# Wildcard Certificates
#------------------------------------------------------------------------------

# *.grahamsmith.net cert removed 2026-05-27 — auto-deleted by AWS
# after the grahamsmith.net Route53 zone deletion + ALB decom left
# it both unvalidated and unused. The grahamsmith.net domain itself
# moved to personal-web repo; no homelab consumer needed a cert for
# it.

# *.etherport.net - Primary homelab domain wildcard
resource "aws_acm_certificate" "etherport_wildcard" {
  domain_name       = "*.etherport.net"
  validation_method = "DNS"
  key_algorithm     = "RSA_2048"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "etherport-wildcard"
  }
}

# *.wind.etherport.net - Wind subdomain wildcard
resource "aws_acm_certificate" "wind_etherport_wildcard" {
  domain_name       = "*.wind.etherport.net"
  validation_method = "DNS"
  key_algorithm     = "RSA_2048"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "wind-etherport-wildcard"
  }
}

#------------------------------------------------------------------------------
# Single-Domain Certificates
#------------------------------------------------------------------------------

# ha.wind.etherport.net - Home Assistant specific certificate
resource "aws_acm_certificate" "ha_wind_etherport" {
  domain_name       = "ha.wind.etherport.net"
  validation_method = "DNS"
  key_algorithm     = "RSA_2048"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "ha-wind-etherport"
  }
}

#------------------------------------------------------------------------------
# DNS Validation Records
#------------------------------------------------------------------------------
# Note: DNS validation records are managed externally in Route53.
# The certificates were created before Terraform management and validation
# records already exist. For new certificates, you would use:
#
# resource "aws_route53_record" "cert_validation" {
#   for_each = {
#     for dvo in aws_acm_certificate.example.domain_validation_options : dvo.domain_name => {
#       name   = dvo.resource_record_name
#       record = dvo.resource_record_value
#       type   = dvo.resource_record_type
#     }
#   }
#   zone_id = var.zone_id
#   name    = each.value.name
#   type    = each.value.type
#   ttl     = 300
#   records = [each.value.record]
# }
