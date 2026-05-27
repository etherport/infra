// stopthecastle.com — static site (S3 → CloudFront) + email forwarding.
//
// Forwarded address: info@stopthecastle.com
//
// Kept: SES setup, root + www CloudFront ALIAS (as CNAME flat),
// 2 × ACM validation CNAMEs (root + www certs), mail. subdomain (SES
// feedback), google-site-verification TXT (Search Console).
// Removed: autodiscover (Outlook).

locals {
  stopthecastle_records = {
    "root-cname-cf" = {
      name    = "@"
      type    = "CNAME"
      content = "d11fmb9a1ds7tz.cloudfront.net"
      comment = "Static site via CloudFront — CF apex CNAME flattening"
    }
    "www-cname-cf" = {
      name    = "www"
      type    = "CNAME"
      content = "d11fmb9a1ds7tz.cloudfront.net"
      comment = "Static site www subdomain"
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
    "google-site-verify" = {
      name    = "@"
      type    = "TXT"
      content = "google-site-verification=xbHjqWi7fU7u3xlPqKsvnWFAp3gFLpQAlR-h3GBgrUw"
      comment = "Google Search Console verification (capture full value from current Route53 if mismatch)"
    }
    "amazonses" = {
      name    = "_amazonses"
      type    = "TXT"
      content = "0PN0bBthvQdpQolVOOxyv7x9PqQqDFiKAzrp/gcm7kk="
      comment = "SES domain verification"
    }
    "dmarc" = {
      name    = "_dmarc"
      type    = "TXT"
      content = "v=DMARC1;p=quarantine;pct=100;fo=1"
      comment = "DMARC"
    }
    "dkim-1" = {
      name    = "5kfgwp3gqae4gvowyb3zzb6a6lo4pcng._domainkey"
      type    = "CNAME"
      content = "5kfgwp3gqae4gvowyb3zzb6a6lo4pcng.dkim.amazonses.com"
      comment = "SES DKIM"
    }
    "dkim-2" = {
      name    = "er5bbnroprhdhzhgks74t5v5pvjxmp4y._domainkey"
      type    = "CNAME"
      content = "er5bbnroprhdhzhgks74t5v5pvjxmp4y.dkim.amazonses.com"
      comment = "SES DKIM"
    }
    "dkim-3" = {
      name    = "k7cjoflqgdbo4degl536uocirfbd5oqq._domainkey"
      type    = "CNAME"
      content = "k7cjoflqgdbo4degl536uocirfbd5oqq.dkim.amazonses.com"
      comment = "SES DKIM"
    }
    "mail-mx" = {
      name    = "mail"
      type    = "MX"
      content = "feedback-smtp.us-west-2.amazonses.com"
      priority = 10
      comment = "SES feedback receiver"
    }
    "mail-spf" = {
      name    = "mail"
      type    = "TXT"
      content = "v=spf1 include:amazonses.com ~all"
      comment = "SPF for mail. subdomain"
    }
    "acm-validation-root" = {
      name    = "_0193dc8643983127999fdf4a163aac18"
      type    = "CNAME"
      content = "_e26fbd2d4427009083d5bc56054550ff.mhbtsbpdnt.acm-validations.aws."
      comment = "ACM validation for stopthecastle.com cert"
    }
    "acm-validation-www" = {
      name    = "_23ca4bb5f71bd2b9085de816711f2959.www"
      type    = "CNAME"
      content = "_a65647677ea68797b44fa977c29c7979.mhbtsbpdnt.acm-validations.aws."
      comment = "ACM validation for www.stopthecastle.com cert"
    }
  }
}

resource "cloudflare_record" "stopthecastle" {
  for_each = local.stopthecastle_records
  zone_id  = var.stopthecastle_zone_id
  name     = each.value.name
  type     = each.value.type
  content  = each.value.content
  priority = lookup(each.value, "priority", null)
  ttl      = lookup(each.value, "ttl", 3600)
  proxied  = false
  comment  = each.value.comment
}
