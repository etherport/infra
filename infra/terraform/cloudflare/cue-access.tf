// =============================================================================
// Cue public access — cue.etherport.net via CF Tunnel + CF Access (Google SSO),
// with PER-PATH policies. The tunnel ingress (main.tf) now serves the whole app
// (the old /health|/telegram path-limit is removed — Telegram is gone); CF Access
// does the gating. CF matches the MOST SPECIFIC app path first, so these three
// apps compose:
//   - cue.etherport.net/health            -> SERVICE AUTH (cue-health-probe token;
//                                            was bypass+everyone until 2026-07-03)
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

// Service token for the NATIVE iOS app (TestFlight, 2026-07-11). A bare
// URLSession cannot complete interactive CF Access Google SSO, so the app
// sends CF-Access-Client-Id/-Secret on every request (same model as the
// healthkit exporter). The token only clears the EDGE — cue's own web-auth
// guard (device token / CF JWT) is the identity layer, so the token alone
// grants nothing. Values are handed to the app owner out-of-band (iOS
// Release xcconfig); the server needs no new env for this.
// Rotate: taint + apply, then update the app build config.
resource "cloudflare_zero_trust_access_service_token" "cue_ios" {
  account_id = var.cloudflare_account_id
  name       = "cue-ios"
  duration   = "8760h" # 1y
}

// Service token for the in-cluster blackbox /health probe (CF Security Insight
// 2026-07-03: "Overprovisioned Access Policies" — the old policy was
// bypass+everyone, which disables ALL edge protections on the path). The probe
// now authenticates like any zero-trust client. Values land in the blackbox
// config secret (platform/kubernetes/blackbox-exporter) via `terraform output`.
resource "cloudflare_zero_trust_access_service_token" "cue_health_probe" {
  account_id = var.cloudflare_account_id
  name       = "cue-health-probe"
  duration   = "8760h" # 1y
}

// 1. /health -> SERVICE AUTH (cue-health-probe token; no unauthenticated access)
resource "cloudflare_zero_trust_access_application" "cue_health" {
  account_id           = var.cloudflare_account_id
  name                 = "Cue — /health (service token)"
  domain               = "cue.etherport.net/health"
  type                 = "self_hosted"
  app_launcher_visible = false
  # non_identity policy: header-auth requests must not bounce to the IdP.
  auto_redirect_to_identity = false
  allowed_idps              = [var.google_idp_id]

  policies = [
    {
      // Was bypass+everyone (CF Insight "Overprovisioned", 2026-07-03). The only
      // legitimate external client is the in-cluster blackbox probe -> service
      // token. non_identity = evaluate the token headers without an IdP bounce.
      name       = "Health probe (service token)"
      decision   = "non_identity"
      precedence = 1
      include = [{
        service_token = { token_id = cloudflare_zero_trust_access_service_token.cue_health_probe.id }
      }]
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

// 3. everything else -> EITHER Google SSO (humans) OR the cue-ios service
//    token (the native app) — CF Access admits a request that satisfies ANY
//    policy. auto_redirect_to_identity flipped to false 2026-07-11: a
//    header-auth (non_identity) request must be EVALUATED, not bounced to the
//    IdP (same reason as the /health + /ingest/healthkit apps above). Humans
//    now see the Access login page with the single Google button — one extra
//    click vs the old instant redirect; unavoidable while one app serves both.
resource "cloudflare_zero_trust_access_application" "cue" {
  account_id                = var.cloudflare_account_id
  name                      = "Cue"
  domain                    = "cue.etherport.net"
  type                      = "self_hosted"
  session_duration          = "24h"
  app_launcher_visible      = true
  auto_redirect_to_identity = false
  allowed_idps              = [var.google_idp_id]

  policies = [
    {
      name       = "Allow cue testers"
      decision   = "allow"
      precedence = 1
      include    = [for e in var.cue_tester_emails : { email = { email = e } }]
    },
    {
      // Native iOS app (TestFlight): whole-app scope is the simplest CORRECT
      // scope — the app's own device-token guard is the real per-user gate,
      // the edge token only proves "our app, not the internet" (mirrors
      // /ingest/healthkit's two-layer model).
      name       = "iOS app (service token)"
      decision   = "non_identity"
      precedence = 2
      include = [{
        service_token = { token_id = cloudflare_zero_trust_access_service_token.cue_ios.id }
      }]
    }
  ]
}

// ---- Values for the cue-api env (it verifies Cf-Access-Jwt-Assertion) --------
output "cue_cf_access_aud" {
  description = "CUE_CF_ACCESS_AUD — the Cue SSO Access app audience (AUD) tag."
  value       = cloudflare_zero_trust_access_application.cue.aud
}

output "cue_ios_service_token_client_id" {
  description = "CF-Access-Client-Id for the native iOS app (TestFlight)."
  value       = cloudflare_zero_trust_access_service_token.cue_ios.client_id
}

output "cue_ios_service_token_client_secret" {
  description = "CF-Access-Client-Secret for the iOS app — `terraform output -raw cue_ios_service_token_client_secret`. Hand to the app owner (xcconfig); never commit."
  value       = cloudflare_zero_trust_access_service_token.cue_ios.client_secret
  sensitive   = true
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
