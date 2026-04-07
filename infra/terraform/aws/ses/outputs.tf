# Outputs for ses module

#------------------------------------------------------------------------------
# Domain Identities
#------------------------------------------------------------------------------

output "etherport_domain_arn" {
  description = "ARN of etherport.net SES domain identity"
  value       = aws_ses_domain_identity.etherport.arn
}

output "etherport_verification_token" {
  description = "Verification token for etherport.net"
  value       = aws_ses_domain_identity.etherport.verification_token
}

output "etherport_dkim_tokens" {
  description = "DKIM tokens for etherport.net"
  value       = aws_ses_domain_dkim.etherport.dkim_tokens
}

output "grahamsmith_domain_arn" {
  description = "ARN of grahamsmith.net SES domain identity"
  value       = aws_ses_domain_identity.grahamsmith.arn
}

output "grahamsmith_verification_token" {
  description = "Verification token for grahamsmith.net"
  value       = aws_ses_domain_identity.grahamsmith.verification_token
}

output "grahamsmith_dkim_tokens" {
  description = "DKIM tokens for grahamsmith.net"
  value       = aws_ses_domain_dkim.grahamsmith.dkim_tokens
}

#------------------------------------------------------------------------------
# Email Identities
#------------------------------------------------------------------------------

output "email_identities" {
  description = "Map of email identities to ARNs"
  value = {
    g_grahamsmith  = aws_ses_email_identity.g_grahamsmith.arn
    grahamsm_gmail = aws_ses_email_identity.grahamsm_gmail.arn
    graham_icloud  = aws_ses_email_identity.graham_icloud.arn
  }
}
