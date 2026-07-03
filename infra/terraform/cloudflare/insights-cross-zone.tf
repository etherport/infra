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

// Bot Fight Mode (Insight, Moderate). Owner decision 2026-07-03: etherport.net
// BFM is managed HERE; the three personal-web zones (grahamsmith/smithforsb/
// stopthecastle) are the personal-web agent's to manage (prompt handed over).
// ⚠️ etherport carries machine traffic (cue API, HealthKit ingest, HA mobile) —
// if BFM challenges break those clients, set fight_mode=false + apply (fast
// rollback) and note it in the tracker. Requires the token scope
// "Zone: Bot Management: Edit" (owner adding).
resource "cloudflare_bot_management" "etherport" {
  zone_id = var.cloudflare_zone_id
  # enable_js (JavaScript Detections) is a hard prerequisite — the API rejects
  # fight_mode while it's off ("cannot enable Fight_Mode while EnableJS is
  # disabled", learned 2026-07-03). JS detection only injects into HTML
  # responses, so the API/machine paths (cue, HealthKit, HA) are untouched by
  # the injection itself; BFM challenge behavior is the thing to watch.
  enable_js  = true
  fight_mode = true
}
