// Cloudflare full-zone management for etherport.net.
//
// CF Free plan doesn't support API-based zone creation OR partial-zone
// (subdomain-only) hosting. So we manage the whole etherport.net zone:
//   1. User manually adds etherport.net via CF dashboard (one-time, 60s)
//   2. TF imports the zone via cloudflare_zone_id var
//   3. TF creates all DNS records (mirrors current Route53 state)
//   4. TF creates Tunnel + Tunnel config + Access app + policy for the
//      AI advisor approval URL (approve.etherport.net)
//   5. User changes etherport.net NS at Route53 Registrar → CF nameservers
//      (the destructive cut-over; reversible)
//
// Architecture:
//   - aws.etherport.net (PRIVATE Route53 zone) stays on Route53 unchanged
//     (VPC-internal resolution, not in public NS chain)
//   - The two ddns writers (ddns-updater Lambda + cloudflare-ddns CronJob)
//     get rewritten to use CF DNS API post-cutover (see runbook)
//
// PROVIDER v5 (M69, 2026-06-13): migrated from cloudflare/cloudflare ~> 4.0.
// Resource renames + structural changes — see
// docs/planning/cloudflare-provider-v5-migration.md. Key changes applied here:
//   - cloudflare_record            -> cloudflare_dns_record (value->content,
//                                     name now full FQDN, allow_overwrite gone)
//   - cloudflare_tunnel            -> cloudflare_zero_trust_tunnel_cloudflared
//                                     (secret -> tunnel_secret)
//   - cloudflare_tunnel_config     -> cloudflare_zero_trust_tunnel_cloudflared_config
//                                     (config{} block -> config = {} attribute;
//                                      ingress_rule{} blocks -> ingress list)
//   - cloudflare_zone              -> account_id -> account.id, zone -> name
//   - Access policies fold inline into the application's `policies` attribute
//     (the standalone application_id/precedence model is gone in v5).

// ---------------------------------------------------------------------------
// 1. Cloudflare zone — imported (NOT created — see top-of-file).
//    To import: `terraform import cloudflare_zone.etherport <zone-id>` after
//    creating the zone in the CF dashboard.
// ---------------------------------------------------------------------------
resource "cloudflare_zone" "etherport" {
  account = {
    id = var.cloudflare_account_id
  }
  name = var.cf_zone_domain
  type = "full"

  // Don't allow accidental TF destroy of the zone — that would delete all
  // records + break DNS authority. Manual cleanup in the dashboard if ever
  // truly needed.
  lifecycle {
    prevent_destroy = true
  }
}

// DNSSEC: CF generates the signing keys + a DS record; the DS record
// must then be published at the REGISTRAR for the parent zone to chain
// trust. Output `etherport_dnssec_ds` shows the DS values to paste into
// the registrar console. Until that step, the zone is signed but the
// chain isn't validated — no security gain or harm.
resource "cloudflare_zone_dnssec" "etherport" {
  zone_id = cloudflare_zone.etherport.id
}

// ---------------------------------------------------------------------------
// 2. DNS records — A, CNAME, MX, TXT.
//    Each resource block uses for_each over the corresponding variable map
//    so adding a new record is a one-line change in variables.tf.
//    v5: name is the full FQDN ("${each.key}.${zone}"), value -> content.
// ---------------------------------------------------------------------------

resource "cloudflare_dns_record" "a" {
  for_each = var.dns_records_a

  zone_id = var.cloudflare_zone_id
  name    = "${each.key}.${var.cf_zone_domain}"
  type    = "A"
  content = each.value.value
  ttl     = each.value.ttl
  proxied = each.value.proxied
  comment = each.value.comment
}

resource "cloudflare_dns_record" "cname" {
  for_each = var.dns_records_cname

  zone_id = var.cloudflare_zone_id
  name    = "${each.key}.${var.cf_zone_domain}"
  type    = "CNAME"
  content = each.value.value
  ttl     = each.value.ttl
  proxied = each.value.proxied
  comment = each.value.comment
}

resource "cloudflare_dns_record" "mx" {
  for_each = var.dns_records_mx

  zone_id  = var.cloudflare_zone_id
  name     = "${each.key}.${var.cf_zone_domain}"
  type     = "MX"
  content  = each.value.value
  priority = each.value.priority
  ttl      = each.value.ttl
  comment  = each.value.comment
}

resource "cloudflare_dns_record" "txt" {
  for_each = var.dns_records_txt

  zone_id = var.cloudflare_zone_id
  name    = "${each.key}.${var.cf_zone_domain}"
  type    = "TXT"
  content = each.value.value
  ttl     = each.value.ttl
  comment = each.value.comment
}

// ---------------------------------------------------------------------------
// 3. Cloudflare Tunnel — the bridge from cluster to CF edge.
//    Secret generated locally → combined with tunnel_id forms TUNNEL_TOKEN
//    that cloudflared daemon needs. Emit as sensitive output for sops-edit.
// ---------------------------------------------------------------------------
resource "random_id" "tunnel_secret" {
  byte_length = 35
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "wind_cluster" {
  account_id    = var.cloudflare_account_id
  name          = "wind-cluster"
  tunnel_secret = random_id.tunnel_secret.b64_std
}

// ---------------------------------------------------------------------------
// 4. Tunnel ingress configuration — declarative routing inside the tunnel.
//    v5: config{} block -> config = {} attribute; ingress_rule{} blocks -> a
//    single `ingress` list of objects; origin_request{} -> origin_request = {}.
//    The static rules + the map-driven services + the required catch-all are
//    concatenated into one ordered list.
// ---------------------------------------------------------------------------
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "wind_cluster" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.wind_cluster.id

  config = {
    ingress = concat(
      [
        {
          hostname = var.approval_hostname
          service  = var.approval_origin_url
          origin_request = {
            no_tls_verify   = false
            connect_timeout = "10s"
          }
        },
        // wiki-js — first migration off the AWS ALB / Traefik public path
        // (2026-05-26). Hostname is wiki.wind.etherport.net (matches site
        // namespacing: wind = the active homelab site).
        {
          hostname = "wiki.wind.etherport.net"
          service  = "http://wiki-js.wikijs.svc.cluster.local:3000"
          origin_request = {
            no_tls_verify   = false
            connect_timeout = "10s"
          }
        },
        // Home Assistant — dual-policy Access app (service token for Alexa
        // Lambda + SSO for browser users). See alexa-service-token.tf.
        {
          hostname = "ha.wind.etherport.net"
          service  = "http://home-assistant.home-automation.svc.cluster.local:8123"
          origin_request = {
            no_tls_verify   = false
            connect_timeout = "10s"
          }
        },
        // Cue API (cue.etherport.net) — single-owner dev app handling personal
        // health data + spending on an LLM key. Deliberately NOT in the
        // cf_tunnel_services map: that wires a CF Access (SSO) app, which would
        // block the Telegram webhook (Telegram can't do SSO). Instead, restrict
        // PUBLIC reachability at the tunnel to exactly the two endpoints that
        // must be internet-facing — the Telegram webhook (app additionally
        // verifies TELEGRAM_WEBHOOK_SECRET) and the health check. Every other
        // path falls through to the 404 catch-all, so it is unreachable from
        // the public internet (owner hits those over Tailscale).
        {
          hostname = "cue.etherport.net"
          path     = "^/health$|^/telegram/webhook/?$"
          service  = "http://cue-api.cue.svc.cluster.local:3000"
          origin_request = {
            no_tls_verify   = false
            connect_timeout = "10s"
          }
        },
      ],
      // All other CF-Tunnel-exposed services come from the cf_tunnel_services
      // map (variables.tf). Add new services there.
      [
        for k, v in var.cf_tunnel_services : {
          hostname = "${k}.etherport.net"
          service  = v.cluster_service_url
          origin_request = {
            no_tls_verify   = false
            connect_timeout = "10s"
          }
        }
      ],
      // Catch-all required by cloudflared
      [
        {
          service = "http_status:404"
        }
      ],
    )
  }
}

// ---------------------------------------------------------------------------
// 5. CNAME for approve.etherport.net → tunnel
//    Apex-level subdomain ("approve" relative to etherport.net zone), so the
//    free Universal SSL cert (covers root + *.etherport.net) handles TLS.
// ---------------------------------------------------------------------------
resource "cloudflare_dns_record" "approve_cname" {
  zone_id = var.cloudflare_zone_id
  name    = "approve.${var.cf_zone_domain}"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.wind_cluster.id}.cfargotunnel.com"
  ttl     = 1    # 1 = auto when proxied
  proxied = true # required for CF Access to intercept
  comment = "CF tunnel for AI advisor approval URL (CF Access in front)"
}

// Cue API — apex-level "cue.etherport.net" so Universal SSL (root +
// *.etherport.net) covers TLS (a valid public cert is required for the
// Telegram webhook). Proxied so the edge terminates TLS and the
// path-restricted tunnel ingress rule applies. NO CF Access app here.
resource "cloudflare_dns_record" "cue_cname" {
  zone_id = var.cloudflare_zone_id
  name    = "cue.${var.cf_zone_domain}"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.wind_cluster.id}.cfargotunnel.com"
  ttl     = 1
  proxied = true
  comment = "CF tunnel for Cue API (public paths: /telegram/webhook + /health only)"
}

// ---------------------------------------------------------------------------
// 6 + 7. CF Access Application — gates the approval URL. v5 folds the policy
// inline (the standalone cloudflare_zero_trust_access_policy + application_id
// model is gone).
// ---------------------------------------------------------------------------
resource "cloudflare_zero_trust_access_application" "approve" {
  account_id                = var.cloudflare_account_id
  name                      = "AI Advisor Approval URL"
  domain                    = var.approval_hostname
  type                      = "self_hosted"
  session_duration          = "24h"
  app_launcher_visible      = false
  auto_redirect_to_identity = true
  allowed_idps              = [var.google_idp_id]

  policies = [
    {
      name       = "Allow listed emails"
      decision   = "allow"
      precedence = 1
      include    = [for e in var.allowed_emails : { email = { email = e } }]
    }
  ]
}

// ---------------------------------------------------------------------------
// wiki-js — first ALB → CF Tunnel migration. (matching ingress rule lives in
// cloudflare_zero_trust_tunnel_cloudflared_config.wind_cluster above.)
// ---------------------------------------------------------------------------
resource "cloudflare_dns_record" "wiki_cname" {
  zone_id = var.cloudflare_zone_id
  name    = "wiki.wind.${var.cf_zone_domain}"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.wind_cluster.id}.cfargotunnel.com"
  ttl     = 1
  proxied = true
  comment = "CF tunnel for wiki-js (CF Access in front)"
}

resource "cloudflare_zero_trust_access_application" "wiki" {
  account_id                = var.cloudflare_account_id
  name                      = "Wiki.js"
  domain                    = "wiki.wind.etherport.net"
  type                      = "self_hosted"
  session_duration          = "24h"
  app_launcher_visible      = true
  auto_redirect_to_identity = true
  allowed_idps              = [var.google_idp_id]

  policies = [
    {
      name       = "Allow listed emails"
      decision   = "allow"
      precedence = 1
      include    = [for e in var.allowed_emails : { email = { email = e } }]
    }
  ]
}

// ---------------------------------------------------------------------------
// Generic CF-Tunnel-exposed services (map-driven).
//
// One DNS CNAME + one Access app (policy inline) per entry in the
// cf_tunnel_services map (variables.tf). Matching tunnel ingress rules
// are generated by the `ingress` concat in the tunnel config above.
// ---------------------------------------------------------------------------
resource "cloudflare_dns_record" "cf_tunnel_services" {
  for_each = var.cf_tunnel_services
  zone_id  = var.cloudflare_zone_id
  name     = "${each.key}.${var.cf_zone_domain}"
  type     = "CNAME"
  content  = "${cloudflare_zero_trust_tunnel_cloudflared.wind_cluster.id}.cfargotunnel.com"
  ttl      = 1
  proxied  = true
  comment  = "CF tunnel for ${each.value.access_name}"
}

resource "cloudflare_zero_trust_access_application" "cf_tunnel_services" {
  for_each                  = var.cf_tunnel_services
  account_id                = var.cloudflare_account_id
  name                      = each.value.access_name
  domain                    = "${each.key}.etherport.net"
  type                      = "self_hosted"
  session_duration          = "24h"
  app_launcher_visible      = true
  auto_redirect_to_identity = true
  allowed_idps              = [var.google_idp_id]

  policies = [
    {
      name       = "Allow listed emails"
      decision   = "allow"
      precedence = 1
      include    = [for e in var.allowed_emails : { email = { email = e } }]
    }
  ]
}
