// Cloudflare Access Service Token for the Home Assistant Alexa skill Lambda.
//
// Pattern: ha.wind.etherport.net is fronted by CF Access (Google SSO for
// browser users). The Alexa skill Lambda calls /api/alexa/smart_home with
// an HA long-lived Bearer token — Lambdas can't follow SSO redirects, so
// they need a "non-identity" bypass. CF Service Tokens are the official
// answer: Lambda sends CF-Access-Client-Id + CF-Access-Client-Secret
// headers, CF checks them against a policy bound to this token, forwards
// to origin if matched.
//
// Order of policies on the HA app:
//   1. (precedence 1) Service token policy — Alexa Lambda lands here
//   2. (precedence 2) SSO policy — browser users land here
//
// Both policies attached to the same Application.
//
// This file is INERT until you uncomment the resources below (after the HA
// migration to CF Tunnel). Until then it sits as documentation + a ready-to-go
// template. Service token resource is commented because:
//   (a) HA Access app isn't created yet — token would be unbound
//   (b) Service Tokens may require a separate token perm
//       (Account: Access: Service Tokens: Edit) beyond Apps and Policies.
//       Add that perm before uncommenting if it isn't already.

// resource "cloudflare_zero_trust_access_service_token" "alexa_skill" {
//   account_id = var.cloudflare_account_id
//   name       = "alexa-skill-lambda"
//
//   // Duration the token is valid before requiring rotation. CF default is
//   // 1y; explicit here for visibility. To rotate: `terraform taint
//   // cloudflare_zero_trust_access_service_token.alexa_skill && terraform apply`,
//   // then update the Lambda env vars with the new client_id/client_secret.
//   duration = "8760h" # 1y
// }
//
// output "alexa_service_token_client_id" {
//   description = "CF Access Service Token client ID. Set as Lambda env var CF_ACCESS_CLIENT_ID."
//   value       = cloudflare_zero_trust_access_service_token.alexa_skill.client_id
// }
//
// output "alexa_service_token_client_secret" {
//   description = "CF Access Service Token client secret. Retrieve via terraform output -raw alexa_service_token_client_secret"
//   value       = cloudflare_zero_trust_access_service_token.alexa_skill.client_secret
//   sensitive   = true
// }

// -------------------------------------------------------------------------
// HA Access Application + dual-policy (SSO + service token) — uncomment
// when migrating ha.wind.etherport.net off the ALB onto CF Tunnel.
// -------------------------------------------------------------------------
//
// resource "cloudflare_zero_trust_access_application" "ha" {
//   account_id                = var.cloudflare_account_id
//   name                      = "Home Assistant"
//   domain                    = "ha.wind.etherport.net"
//   type                      = "self_hosted"
//   session_duration          = "24h"
//   app_launcher_visible      = true
//   auto_redirect_to_identity = true
// }
//
// resource "cloudflare_zero_trust_access_policy" "ha_alexa_service_token" {
//   account_id     = var.cloudflare_account_id
//   application_id = cloudflare_zero_trust_access_application.ha.id
//   name           = "Alexa skill Lambda (service token bypass)"
//   precedence     = 1   # evaluated first; non-identity matches short-circuit
//   decision       = "non_identity"
//   include {
//     service_token = [cloudflare_zero_trust_access_service_token.alexa_skill.id]
//   }
// }
//
// resource "cloudflare_zero_trust_access_policy" "ha_sso" {
//   account_id     = var.cloudflare_account_id
//   application_id = cloudflare_zero_trust_access_application.ha.id
//   name           = "Allow listed emails (browser users)"
//   precedence     = 2
//   decision       = "allow"
//   include {
//     email = var.allowed_emails
//   }
// }
//
// Also: add a tunnel ingress rule for ha.wind.etherport.net in main.tf
// cloudflare_tunnel_config.config.ingress_rule[] pointing at the
// in-cluster HA Service, then a CNAME record:
//
// resource "cloudflare_record" "ha_cname" {
//   zone_id = cloudflare_zone.wind.id
//   name    = "ha"
//   type    = "CNAME"
//   value   = "${cloudflare_tunnel.wind_cluster.id}.cfargotunnel.com"
//   ttl     = 1
//   proxied = true
//   comment = "HA via CF tunnel — replaces the ALB alias in existing_wind_records"
// }
//
// Finally, update the Lambda env in infra/terraform/aws/homeassistant-alexa/
// to include CF_ACCESS_CLIENT_ID + CF_ACCESS_CLIENT_SECRET, and update the
// Lambda code (~3 lines) to add those headers on outbound requests:
//
//   headers['CF-Access-Client-Id'] = os.environ['CF_ACCESS_CLIENT_ID']
//   headers['CF-Access-Client-Secret'] = os.environ['CF_ACCESS_CLIENT_SECRET']
