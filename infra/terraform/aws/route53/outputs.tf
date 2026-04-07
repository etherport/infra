# Outputs for route53 module

#------------------------------------------------------------------------------
# Hosted Zones
#------------------------------------------------------------------------------

output "etherport_zone_id" {
  description = "Zone ID for etherport.net"
  value       = aws_route53_zone.etherport.zone_id
}

output "etherport_name_servers" {
  description = "Name servers for etherport.net"
  value       = aws_route53_zone.etherport.name_servers
}

output "grahamsmith_zone_id" {
  description = "Zone ID for grahamsmith.net"
  value       = aws_route53_zone.grahamsmith.zone_id
}

output "grahamsmith_name_servers" {
  description = "Name servers for grahamsmith.net"
  value       = aws_route53_zone.grahamsmith.name_servers
}
