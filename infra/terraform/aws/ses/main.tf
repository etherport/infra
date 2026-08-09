# SES Identities for homelab email
#
# Domain identities:
# - etherport.net - Primary homelab domain
#
# Email identities (homelab-owned forward TARGETS):
# - grahamsm@gmail.com - Gmail backup
# - graham.m.smith@me.com - iCloud email
#
# NOT managed (moved out 2026-05-27):
# - grahamsmith.net, smithforsb.com, stopthecastle.com SES identities +
#   DKIM live in the personal-web repo
#   (etherport/personal-web :: terraform/ses-email-forward)
# - g@grahamsmith.net email identity moved there too (it's the personal-
#   web verified sender used by the fwd_graham receipt rule)

#------------------------------------------------------------------------------
# Domain Identities
#------------------------------------------------------------------------------

resource "aws_ses_domain_identity" "etherport" {
  domain = "etherport.net"
}

resource "aws_ses_domain_dkim" "etherport" {
  domain = aws_ses_domain_identity.etherport.domain
}

#------------------------------------------------------------------------------
# Email Identities (homelab-owned forward TARGETS)
#------------------------------------------------------------------------------

resource "aws_ses_email_identity" "grahamsm_gmail" {
  email = "grahamsm@gmail.com"
}

resource "aws_ses_email_identity" "graham_icloud" {
  email = "graham.m.smith@me.com"
}

#------------------------------------------------------------------------------
# DNS Records for Verification (Reference)
#------------------------------------------------------------------------------
# Domain verification and DKIM records for etherport.net live in the
# cloudflare module (infra/terraform/cloudflare/variables.tf).
# Tokens:
#   - dy5wbhsewzcikzt45twscs2dl4g4vma2._domainkey.etherport.net
#   - j5gqverli76qyzmlg6ulzs2ey36w6rgb._domainkey.etherport.net
#   - 5gniifohq7dsyc2lphgcnx4j3a74ofco._domainkey.etherport.net
