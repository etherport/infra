// smithforsb.com — CF edge redirect to Instagram + email forwarding.
//
// Apex + www → https://www.instagram.com/graham.m.smith/ via a CF
// Single Redirect rule at the edge. No origin needed; the AWS static
// site stack (CloudFront + S3 + ACM) is decommissioned.
//
// Forwarded addresses (kept, separate from web): graham@, info@smithforsb.com

locals {
  smithforsb_records = {
    # Apex must be proxied so CF terminates the request and applies
    # the redirect rule — 192.0.2.1 is TEST-NET-1, deliberately
    # unrouteable. If the redirect rule is ever removed, requests
    # blackhole rather than leaking to a real host.
    "root-a-redirect-target" = {
      name    = "@"
      type    = "A"
      content = "192.0.2.1"
      comment = "Proxied placeholder — CF Single Redirect intercepts at edge"
      proxied = true
      ttl     = 1  # CF requires ttl=1 when proxied
    }
    "www-cname" = {
      name    = "www"
      type    = "CNAME"
      content = "smithforsb.com"
      comment = "www → apex, proxied so the redirect rule applies"
      proxied = true
      ttl     = 1
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

# Single Redirect rule: smithforsb.com (+ www) → IG profile, 301, drop
# any path / query string (IG URLs don't share our path space).
resource "cloudflare_ruleset" "smithforsb_to_instagram" {
  zone_id     = var.smithforsb_zone_id
  name        = "smithforsb -> Instagram"
  description = "Redirect all traffic to https://www.instagram.com/graham.m.smith/"
  kind        = "zone"
  phase       = "http_request_dynamic_redirect"

  rules {
    action      = "redirect"
    expression  = "(http.host eq \"smithforsb.com\") or (http.host eq \"www.smithforsb.com\")"
    description = "All paths to graham.m.smith IG profile"
    enabled     = true
    action_parameters {
      from_value {
        status_code           = 301
        preserve_query_string = false
        target_url {
          value = "https://www.instagram.com/graham.m.smith/"
        }
      }
    }
  }
}
