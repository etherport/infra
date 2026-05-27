// grahamsmith.net — email forwarding only (no website).
//
// Forwarded addresses (via the email-forward Lambda, ../aws/email-forward/):
//   g@, graham@, me@, windtryst@, workroom@grahamsmith.net
//
// Kept records: SES inbound + sending (DKIM/SPF/DMARC) + mail. subdomain
// (SES feedback). Removed: autodiscover (Outlook), vpn (migrated),
// windtryst (legacy gmsmeg.net target — zone deprecated, replaced by
// sip.wind.etherport.net), _4239d3 (validation for orphan ACM cert).

locals {
  grahamsmith_records = {
    # ---- SES inbound + sender auth ----
    "root-mx" = {
      name    = "@"
      type    = "MX"
      content = "inbound-smtp.us-west-2.amazonaws.com"
      priority = 10
      comment = "SES inbound — email forwarding Lambda receives here"
    }
    "root-spf" = {
      name    = "@"
      type    = "TXT"
      content = "v=spf1 include:amazonses.com ~all"
      comment = "SPF — SES sender auth"
    }
    "amazonses" = {
      name    = "_amazonses"
      type    = "TXT"
      content = "YxfS57XyZukjaILeiPOHCr3qnLHK5s9bVQ+pD/PnRZ4="
      comment = "SES domain verification"
    }
    "dmarc" = {
      name    = "_dmarc"
      type    = "TXT"
      content = "v=DMARC1; p=none;"
      comment = "DMARC policy"
    }
    "dkim-1" = {
      name    = "345d4ydpdtelkytksyw7wvzuctho5nus._domainkey"
      type    = "CNAME"
      content = "345d4ydpdtelkytksyw7wvzuctho5nus.dkim.amazonses.com"
      comment = "SES DKIM"
    }
    "dkim-2" = {
      name    = "637qs2t6wu5i4n5na7dnsf5j5p2ufhao._domainkey"
      type    = "CNAME"
      content = "637qs2t6wu5i4n5na7dnsf5j5p2ufhao.dkim.amazonses.com"
      comment = "SES DKIM"
    }
    "dkim-3" = {
      name    = "wrdadq56jdbha57jnrveghemnjco2y5b._domainkey"
      type    = "CNAME"
      content = "wrdadq56jdbha57jnrveghemnjco2y5b.dkim.amazonses.com"
      comment = "SES DKIM"
    }
    "mail-mx" = {
      name    = "mail"
      type    = "MX"
      content = "feedback-smtp.us-west-2.amazonses.com"
      priority = 10
      comment = "SES feedback (bounces)"
    }
    "mail-spf" = {
      name    = "mail"
      type    = "TXT"
      content = "v=spf1 include:amazonses.com ~all"
      comment = "SPF for mail. subdomain"
    }
  }
}

resource "cloudflare_record" "grahamsmith" {
  for_each = local.grahamsmith_records
  zone_id  = var.grahamsmith_zone_id
  name     = each.value.name
  type     = each.value.type
  content  = each.value.content
  priority = lookup(each.value, "priority", null)
  ttl      = lookup(each.value, "ttl", 3600)
  proxied  = false   # all mail records — never proxy
  comment  = each.value.comment
}
