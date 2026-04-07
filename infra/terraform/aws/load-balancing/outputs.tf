# Outputs for load-balancing module

#------------------------------------------------------------------------------
# Load Balancer
#------------------------------------------------------------------------------

output "alb_arn" {
  description = "ARN of the Application Load Balancer"
  value       = aws_lb.main.arn
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  description = "Route53 zone ID of the Application Load Balancer"
  value       = aws_lb.main.zone_id
}

#------------------------------------------------------------------------------
# Target Group
#------------------------------------------------------------------------------

output "traefik_target_group_arn" {
  description = "ARN of the Traefik target group"
  value       = aws_lb_target_group.traefik.arn
}

#------------------------------------------------------------------------------
# Listener
#------------------------------------------------------------------------------

output "https_listener_arn" {
  description = "ARN of the HTTPS listener"
  value       = aws_lb_listener.https.arn
}

#------------------------------------------------------------------------------
# Certificates in use
#------------------------------------------------------------------------------

output "certificates" {
  description = "ACM certificates attached to the listener"
  value = {
    default            = data.aws_acm_certificate.grahamsmith_wildcard.arn
    etherport_wildcard = data.aws_acm_certificate.etherport_wildcard.arn
    wind_wildcard      = data.aws_acm_certificate.wind_etherport_wildcard.arn
    ha_wind            = data.aws_acm_certificate.ha_wind_etherport.arn
  }
}
