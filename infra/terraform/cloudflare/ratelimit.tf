// M148 (2026-07-25): per-IP rate limit on the un-gated public Plex hostname.
//
// plex.wind.etherport.net has NO CF Access since 2026-07-25 (Plex apps can't do
// interactive SSO) — auth is Plex's own plex.tv account tokens. Actual Plex
// SIGN-IN happens against plex.tv (not our origin), so the abuse surface here is
// token brute-forcing / API scraping against the server itself. This caps any
// single IP at 300 requests per 10s window (free-plan constraints: one rule,
// 10s period, block-only) — far above a legitimate client burst (web-app cold
// load ≈ 50-100 req; DASH streaming ≈ 1 req/2-5s) but throttles automated
// hammering to ≤30 req/s sustained. Scoped to the plex host only; every other
// hostname keeps CF Access SSO in front.
resource "cloudflare_ruleset" "zone_ratelimit" {
  zone_id     = var.cloudflare_zone_id
  name        = "Zone rate limits"
  description = "Per-IP rate limits (M148: public Plex host)"
  kind        = "zone"
  phase       = "http_ratelimit"

  rules = [
    {
      ref         = "plex_per_ip"
      description = "Plex (un-gated): cap 300 req/10s per IP"
      expression  = "(http.host eq \"plex.wind.etherport.net\")"
      action      = "block"
      ratelimit = {
        characteristics     = ["ip.src", "cf.colo.id"]
        period              = 10
        requests_per_period = 300
        mitigation_timeout  = 10
      }
      enabled = true
    }
  ]
}
