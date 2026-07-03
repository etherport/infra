// =============================================================================
// CF Security Insights remediation (2026-07-03 CSV) — cross-zone items.
// The stack historically managed only etherport.net; these use zone lookups.
// If the CI token turns out zone-scoped to etherport, the plan 403s harmlessly
// and these move to the dashboard checklist instead.
// =============================================================================

data "cloudflare_zones" "grahamsmith" {
  name = "grahamsmith.net"
}
data "cloudflare_zones" "stopthecastle" {
  name = "stopthecastle.com"
}
data "cloudflare_zones" "smithforsb" {
  name = "smithforsb.com"
}

// SPF hardening (Insight: "SPF Record Errors", Moderate): the mail.* names are
// MX targets that only RECEIVE — a hard-fail SPF on names that never send is
// the standard anti-spoofing fix and breaks nothing (SPF governs MAIL FROM use
// of the name, not receipt). The apex domains' own SPF records are untouched.
resource "cloudflare_dns_record" "spf_mail_grahamsmith" {
  zone_id = data.cloudflare_zones.grahamsmith.result[0].id
  name    = "mail.grahamsmith.net"
  type    = "TXT"
  content = "\"v=spf1 -all\""
  ttl     = 3600
}

resource "cloudflare_dns_record" "spf_mail_stopthecastle" {
  zone_id = data.cloudflare_zones.stopthecastle.result[0].id
  name    = "mail.stopthecastle.com"
  type    = "TXT"
  content = "\"v=spf1 -all\""
  ttl     = 3600
}

// Bot Fight Mode (Insight, Moderate) — the three STATIC sites only. etherport.net
// deliberately EXCLUDED: it carries machine traffic (cue API + HealthKit ingest +
// HA mobile/webhooks) that BFM is known to challenge/break; pending owner call.
resource "cloudflare_bot_management" "grahamsmith" {
  zone_id    = data.cloudflare_zones.grahamsmith.result[0].id
  fight_mode = true
}
resource "cloudflare_bot_management" "stopthecastle" {
  zone_id    = data.cloudflare_zones.stopthecastle.result[0].id
  fight_mode = true
}
resource "cloudflare_bot_management" "smithforsb" {
  zone_id    = data.cloudflare_zones.smithforsb.result[0].id
  fight_mode = true
}
