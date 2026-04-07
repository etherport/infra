# Outputs for acm module

output "grahamsmith_wildcard_arn" {
  description = "ARN of the *.grahamsmith.net certificate"
  value       = aws_acm_certificate.grahamsmith_wildcard.arn
}

output "etherport_wildcard_arn" {
  description = "ARN of the *.etherport.net certificate"
  value       = aws_acm_certificate.etherport_wildcard.arn
}

output "wind_etherport_wildcard_arn" {
  description = "ARN of the *.wind.etherport.net certificate"
  value       = aws_acm_certificate.wind_etherport_wildcard.arn
}

output "ha_wind_etherport_arn" {
  description = "ARN of the ha.wind.etherport.net certificate"
  value       = aws_acm_certificate.ha_wind_etherport.arn
}

# Map of all certificate ARNs for easy reference
output "certificates" {
  description = "Map of all certificate ARNs"
  value = {
    grahamsmith_wildcard    = aws_acm_certificate.grahamsmith_wildcard.arn
    etherport_wildcard      = aws_acm_certificate.etherport_wildcard.arn
    wind_etherport_wildcard = aws_acm_certificate.wind_etherport_wildcard.arn
    ha_wind_etherport       = aws_acm_certificate.ha_wind_etherport.arn
  }
}
