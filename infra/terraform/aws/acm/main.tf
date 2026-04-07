# ACM Certificates for homelab infrastructure (us-west-2)
#
# These certificates are used by the ALB for HTTPS termination.
# DNS validation records are managed in the route53 module.

#------------------------------------------------------------------------------
# Wildcard Certificates
#------------------------------------------------------------------------------

# *.grahamsmith.net - Personal domain wildcard
resource "aws_acm_certificate" "grahamsmith_wildcard" {
  domain_name       = "*.grahamsmith.net"
  validation_method = "DNS"
  key_algorithm     = "RSA_2048"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "grahamsmith-wildcard"
  }
}

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
