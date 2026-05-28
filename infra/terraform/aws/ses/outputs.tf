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

# grahamsmith.net domain identity outputs moved to personal-web repo
# (terraform/ses-email-forward/outputs.tf) along with the resource on
# 2026-05-27.

#------------------------------------------------------------------------------
# Email Identities
#------------------------------------------------------------------------------

output "email_identities" {
  description = "Map of email identities to ARNs"
  value = {
    grahamsm_gmail = aws_ses_email_identity.grahamsm_gmail.arn
    graham_icloud  = aws_ses_email_identity.graham_icloud.arn
  }
}
