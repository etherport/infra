# Route53 Hosted Zones
# Homelab domains - etherport.net and grahamsmith.net

#------------------------------------------------------------------------------
# etherport.net - Primary homelab domain
#------------------------------------------------------------------------------

resource "aws_route53_zone" "etherport" {
  name    = "etherport.net"
  comment = "Primary homelab domain"

  lifecycle {
    prevent_destroy = true
  }
}

#------------------------------------------------------------------------------
# grahamsmith.net - Personal domain
#------------------------------------------------------------------------------

resource "aws_route53_zone" "grahamsmith" {
  name    = "grahamsmith.net"
  comment = "Personal domain"

  lifecycle {
    prevent_destroy = true
  }
}
