// =============================================================================
// Cue public access — cue.etherport.net via CF Tunnel + CF Access (Google SSO),
// with PER-PATH policies. The tunnel ingress (main.tf) now serves the whole app
// (the old /health|/telegram path-limit is removed — Telegram is gone); CF Access
// does the gating. CF matches the MOST SPECIFIC app path first, so these three
// apps compose:
//   - cue.etherport.net/health            -> BYPASS (no login; data-free liveness)
//   - cue.etherport.net/ingest/healthkit  -> SERVICE AUTH (CF service token only;
//                                            the Apple Health Auto Export app
//                                            can't do interactive SSO)
//   - cue.etherport.net                    -> ALLOW cue testers (Google SSO, 24h)
//
// The app ALSO verifies the injected Cf-Access-Jwt-Assertion (aud = the SSO app
// below) to map the Google email -> Cue user — see CUE_CF_ACCESS_* on cue-api.
// The app keeps its own per-user HMAC token (CUE_WEB_AUTH) as the identity layer;
// CF Access is the outer gate.
// =============================================================================

// Service token for the HealthKit ingest client (Apple Health Auto Export).
// The export app sends CF-Access-Client-Id + CF-Access-Client-Secret headers.
// Rotate: `terraform taint cloudflare_zero_trust_access_service_token.cue_healthkit
// && terraform apply`, then update the export app's headers.
resource "cloudflare_zero_trust_access_service_token" "cue_healthkit" {
  account_id = var.cloudflare_account_id
  name       = "cue-healthkit-ingest"
  duration   = "8760h" # 1y
}

// 1. /health -> BYPASS (public, unauthenticated liveness probe)
resource "cloudflare_zero_trust_access_application" "cue_health" {
  account_id           = var.cloudflare_account_id
  name                 = "Cue — /health (public)"
  domain               = "cue.etherport.net/health"
  type                 = "self_hosted"
  app_launcher_visible = false
  allowed_idps         = [var.google_idp_id]

  policies = [
    {
      name       = "Public bypass (liveness)"
      decision   = "bypass"
      precedence = 1
      include    = [{ everyone = {} }]
    }
  ]
}

// 2. /ingest/healthkit (+ subpaths) -> SERVICE AUTH (CF service token only).
//    auto_redirect_to_identity must be false so a non-identity (header) request
//    is evaluated against the token instead of bouncing to the IdP.
resource "cloudflare_zero_trust_access_application" "cue_healthkit" {
  account_id                = var.cloudflare_account_id
  name                      = "Cue — /ingest/healthkit (service token)"
  domain                    = "cue.etherport.net/ingest/healthkit"
  type                      = "self_hosted"
  session_duration          = "24h"
  app_launcher_visible      = false
  auto_redirect_to_identity = false
  allowed_idps              = [var.google_idp_id]

  policies = [
    {
      name       = "HealthKit ingest service token"
      decision   = "non_identity"
      precedence = 1
      include = [
        {
          service_token = {
            token_id = cloudflare_zero_trust_access_service_token.cue_healthkit.id
          }
        }
      ]
    }
  ]
}

// 3. everything else -> ALLOW cue testers (Google SSO, 24h session)
resource "cloudflare_zero_trust_access_application" "cue" {
  account_id                = var.cloudflare_account_id
  name                      = "Cue"
  domain                    = "cue.etherport.net"
  type                      = "self_hosted"
  session_duration          = "24h"
  app_launcher_visible      = true
  auto_redirect_to_identity = true
  allowed_idps              = [var.google_idp_id]

  policies = [
    {
      name       = "Allow cue testers"
      decision   = "allow"
      precedence = 1
      include    = [for e in var.cue_tester_emails : { email = { email = e } }]
    }
  ]
}

// ---- Values for the cue-api env (it verifies Cf-Access-Jwt-Assertion) --------
output "cue_cf_access_aud" {
  description = "CUE_CF_ACCESS_AUD — the Cue SSO Access app audience (AUD) tag."
  value       = cloudflare_zero_trust_access_application.cue.aud
}

output "cue_healthkit_service_token_client_id" {
  description = "CF-Access-Client-Id for the Apple Health Auto Export app."
  value       = cloudflare_zero_trust_access_service_token.cue_healthkit.client_id
}

output "cue_healthkit_service_token_client_secret" {
  description = "CF-Access-Client-Secret for the export app — `terraform output -raw cue_healthkit_service_token_client_secret`."
  value       = cloudflare_zero_trust_access_service_token.cue_healthkit.client_secret
  sensitive   = true
}
