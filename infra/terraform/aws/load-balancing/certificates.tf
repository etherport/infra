# ACM Certificate Data Sources
#
# These certificates are managed by ACM (auto-renewal) and referenced here.
# We use data sources rather than resources to avoid managing the certificates
# directly in Terraform.

#------------------------------------------------------------------------------
# Active Certificates (etherport.net, grahamsmith.net)
#------------------------------------------------------------------------------

data "aws_acm_certificate" "grahamsmith_wildcard" {
  domain      = "*.grahamsmith.net"
  statuses    = ["ISSUED"]
  most_recent = true
}

data "aws_acm_certificate" "etherport_wildcard" {
  domain      = "*.etherport.net"
  statuses    = ["ISSUED"]
  most_recent = true
}

data "aws_acm_certificate" "wind_etherport_wildcard" {
  domain      = "*.wind.etherport.net"
  statuses    = ["ISSUED"]
  most_recent = true
}

data "aws_acm_certificate" "ha_wind_etherport" {
  domain      = "ha.wind.etherport.net"
  statuses    = ["ISSUED"]
  most_recent = true
}
