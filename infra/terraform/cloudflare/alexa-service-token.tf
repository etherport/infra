// Cloudflare Access Service Token + HA Access app (dual-policy).
//
// Pattern: ha.wind.etherport.net is fronted by CF Access (Google SSO for
// browser users). The Alexa skill Lambda calls /api/alexa/smart_home with
// an HA long-lived Bearer token — Lambdas can't follow SSO redirects, so
// they need a "non-identity" bypass. CF Service Tokens are the official
// answer: Lambda sends CF-Access-Client-Id + CF-Access-Client-Secret
// headers, CF checks them against a policy bound to this token, forwards
// to origin if matched.
//
// Order of policies on the HA app (v5: inline in `policies`, ordered by
// precedence):
//   1. (precedence 1) Service token policy — Alexa Lambda lands here
//   2. (precedence 2) SSO policy — browser users land here

resource "cloudflare_zero_trust_access_service_token" "alexa_skill" {
  account_id = var.cloudflare_account_id
  name       = "alexa-skill-lambda"

  // Duration the token is valid before requiring rotation. CF default is
  // 1y; explicit here for visibility. To rotate: `terraform taint
  // cloudflare_zero_trust_access_service_token.alexa_skill && terraform apply`,
  // then update the Lambda env vars with the new client_id/client_secret.
  duration = "8760h" # 1y
}

output "alexa_service_token_client_id" {
  description = "CF Access Service Token client ID. Set as Lambda env var CF_ACCESS_CLIENT_ID."
  value       = cloudflare_zero_trust_access_service_token.alexa_skill.client_id
}

output "alexa_service_token_client_secret" {
  description = "CF Access Service Token client secret. Retrieve via `terraform output -raw alexa_service_token_client_secret`."
  value       = cloudflare_zero_trust_access_service_token.alexa_skill.client_secret
  sensitive   = true
}

// -------------------------------------------------------------------------
// HA Access Application + dual-policy (SSO + service token), inline (v5).
// -------------------------------------------------------------------------

resource "cloudflare_zero_trust_access_application" "ha" {
  account_id           = var.cloudflare_account_id
  name                 = "Home Assistant"
  domain               = "ha.wind.etherport.net"
  type                 = "self_hosted"
  session_duration     = "24h"
  app_launcher_visible = true
  // auto_redirect_to_identity intentionally false here — a service-token
  // request must reach CF Access without a redirect; SSO browser users
  // get the IdP picker (single IdP = effectively automatic).
  auto_redirect_to_identity = false
  allowed_idps              = [var.google_idp_id]

  policies = [
    // 1. evaluated first; non-identity service-token match short-circuits
    {
      name       = "Alexa skill Lambda (service token bypass)"
      decision   = "non_identity"
      precedence = 1
      include = [
        {
          service_token = {
            token_id = cloudflare_zero_trust_access_service_token.alexa_skill.id
          }
        }
      ]
    },
    // 2. browser users
    {
      name       = "Allow listed emails (browser users)"
      decision   = "allow"
      precedence = 2
      include    = [for e in var.allowed_emails : { email = { email = e } }]
    },
  ]
}

// -------------------------------------------------------------------------
// CNAME for ha.wind.etherport.net → tunnel.
// -------------------------------------------------------------------------

resource "cloudflare_dns_record" "ha_cname" {
  zone_id = var.cloudflare_zone_id
  name    = "ha.wind.${var.cf_zone_domain}"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.wind_cluster.id}.cfargotunnel.com"
  ttl     = 1
  proxied = true
  comment = "HA via CF tunnel — replaces the ALB alias"
}

// -------------------------------------------------------------------------
// Lambda-side follow-up (manual or future TF):
//
// 1. Capture service token outputs:
//      cd infra/terraform/cloudflare
//      terraform output -raw alexa_service_token_client_id
//      terraform output -raw alexa_service_token_client_secret
//
// 2. Pass to the alexa Lambda module via TF_VAR:
//      cd infra/terraform/aws/homeassistant-alexa
//      TF_VAR_cf_access_client_id=<id> \
//      TF_VAR_cf_access_client_secret=<secret> \
//      terraform apply
//
//    (The Lambda module's variables.tf + main.tf wires these into the
//    Lambda's environment; handler.py reads them and adds the headers
//    on outbound requests to ha.wind.etherport.net.)
//
// 3. Test: trigger an Alexa Smart Home directive ("Alexa, turn on the
//    living room") and watch the Lambda CloudWatch logs. Successful
//    HTTP 200 from /api/alexa/smart_home means the service token bypass
//    worked. 403 = CF Access rejected the headers (check that the token
//    UUID matches the service_token UUID in the ha_alexa policy).
