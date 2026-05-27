// smithforsb.com — static site (S3 → CloudFront) + email forwarding.
//
// Forwarded addresses: graham@, info@, mark@smithforsb.com
//
// Kept: SES setup, ACM validation, root CNAME-flat → CloudFront.
// Removed: autodiscover (Outlook), legacy `scph1023._domainkey` (old
// SendGrid DKIM, unused now that email-forward uses SES).

locals {
  smithforsb_records = {
    "root-cname-cf" = {
      name    = "@"
      type    = "CNAME"
      content = "d1v54h83zvkl2t.cloudfront.net"
      comment = "Static site via CloudFront — CF apex CNAME flattening"
      proxied = false
    }
    "root-mx" = {
      name    = "@"
      type    = "MX"
      content = "inbound-smtp.us-west-2.amazonaws.com"
      priority = 10
      comment = "SES inbound — email forwarding"
    }
    "root-spf" = {
      name    = "@"
      type    = "TXT"
      content = "v=spf1 include:amazonses.com ~all"
      comment = "SPF"
    }
    "amazonses" = {
      name    = "_amazonses"
      type    = "TXT"
      content = "2A7wxbfXu4QmXPNvyIxaJfDRzfQG/ARjbQrHLJ6SEUY="
      comment = "SES domain verification"
    }
    "dmarc" = {
      name    = "_dmarc"
      type    = "TXT"
      content = "v=DMARC1;p=quarantine;pct=100;fo=1"
      comment = "DMARC"
    }
    "dkim-1" = {
      name    = "2p7pdor2nrbo33xmcmkomkbxcdvxouos._domainkey"
      type    = "CNAME"
      content = "2p7pdor2nrbo33xmcmkomkbxcdvxouos.dkim.amazonses.com"
      comment = "SES DKIM"
    }
    "dkim-2" = {
      name    = "qwydzk5mool4piekllal3hkrcrgljkyk._domainkey"
      type    = "CNAME"
      content = "qwydzk5mool4piekllal3hkrcrgljkyk.dkim.amazonses.com"
      comment = "SES DKIM"
    }
    "dkim-3" = {
      name    = "zkdlvopdqntati2n5wjr4aimmsk7vpbo._domainkey"
      type    = "CNAME"
      content = "zkdlvopdqntati2n5wjr4aimmsk7vpbo.dkim.amazonses.com"
      comment = "SES DKIM"
    }
    "acm-validation-root" = {
      name    = "_8e796d07b00603f3bba23357a8e930d5"
      type    = "CNAME"
      content = "_fd9cd767c7dd5df12e0bfb218ea64249.mhbtsbpdnt.acm-validations.aws."
      comment = "ACM validation for *.smithforsb.com cert (us-east-1, CloudFront)"
    }
  }
}

resource "cloudflare_record" "smithforsb" {
  for_each = local.smithforsb_records
  zone_id  = var.smithforsb_zone_id
  name     = each.value.name
  type     = each.value.type
  content  = each.value.content
  priority = lookup(each.value, "priority", null)
  ttl      = lookup(each.value, "ttl", 3600)
  proxied  = lookup(each.value, "proxied", false)
  comment  = each.value.comment
}
