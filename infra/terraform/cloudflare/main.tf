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
// The full v5 rename map + structural changes (record->dns_record, tunnel/config
// renames, zone account nesting, inline Access policies) are documented in
// docs/planning/cloudflare-provider-v5-migration.md — kept there rather than
// inline so the per-resource comments below stay the source of truth.

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

  // v5 makes `status` a settable attribute: omitting it plans status -> null
  // (which would DISABLE DNSSEC), and pinning "active" fights any zone CF has
  // server-side pending. Activation is a CF lifecycle, not TF-driven — ignore
  // it. (Learned from the personal-web v5 migration, 2026-06-13.)
  lifecycle {
    ignore_changes = [status]
  }
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
  // Ingress is managed remotely via the API (the _config resource below), so
  // the tunnel's config source is "cloudflare", not the local cloudflared file.
  config_src = "cloudflare"

  // tunnel_secret is write-only — the API never returns it, so after import
  // state has no secret and a plan would want to (re)set it from random_id,
  // re-issuing the tunnel token and dropping the live cloudflared connection.
  // The tunnel already exists with a working token; manage it, don't rotate.
  // (To deliberately rotate: remove this, taint random_id, apply, then
  //  redeploy platform/kubernetes/cloudflared/01-tunnel-token.sops.yaml.)
  lifecycle {
    ignore_changes = [tunnel_secret]
  }
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

  // v5: config{} block -> config = {} attribute; ingress_rule{} blocks -> a
  // single `ingress` list. Every element carries the SAME keys (hostname/path/
  // service/origin_request, null where N/A) so concat() unifies to one object
  // type. connect_timeout is a NUMBER of seconds in v5 (not the v4 "10s").
  config = {
    ingress = concat(
      [
        {
          hostname       = var.approval_hostname
          path           = null
          service        = var.approval_origin_url
          origin_request = { no_tls_verify = false, connect_timeout = 10 }
        },
        // wiki-js — migrated off the AWS ALB / Traefik public path (2026-05-26).
        {
          hostname       = "wiki.wind.etherport.net"
          path           = null
          service        = "http://wiki-js.wikijs.svc.cluster.local:3000"
          origin_request = { no_tls_verify = false, connect_timeout = 10 }
        },
        // Home Assistant — dual-policy Access app (Alexa service token + SSO).
        {
          hostname       = "ha.wind.etherport.net"
          path           = null
          service        = "http://home-assistant.home-automation.svc.cluster.local:8123"
          origin_request = { no_tls_verify = false, connect_timeout = 10 }
        },
        // Cue API — serves the WHOLE app now (2026-06-23); CF Access does the
        // gating via per-path apps in cue-access.tf (testers SSO / /health bypass
        // / /ingest/healthkit service token). Telegram is removed, so the old
        // path-limit is gone. NOT in the cf_tunnel_services map because that wires
        // a single blanket SSO policy; cue needs the per-path Access apps instead.
        {
          hostname       = "cue.etherport.net"
          path           = null
          service        = "http://cue-api.cue.svc.cluster.local:3000"
          origin_request = { no_tls_verify = false, connect_timeout = 10 }
        },
      ],
      // All other CF-Tunnel-exposed services come from the cf_tunnel_services
      // map (variables.tf). Add new services there.
      [
        for k, v in var.cf_tunnel_services : {
          hostname       = "${k}.etherport.net"
          path           = null
          service        = v.cluster_service_url
          origin_request = { no_tls_verify = false, connect_timeout = 10 }
        }
      ],
      // Catch-all required by cloudflared (same key shape, nulls for N/A).
      [
        {
          hostname       = null
          path           = null
          service        = "http_status:404"
          origin_request = null
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
// *.etherport.net) covers TLS. Proxied so the edge terminates TLS and CF Access
// intercepts. Whole app served; CF Access apps (cue-access.tf) gate per path.
resource "cloudflare_dns_record" "cue_cname" {
  zone_id = var.cloudflare_zone_id
  name    = "cue.${var.cf_zone_domain}"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.wind_cluster.id}.cfargotunnel.com"
  ttl     = 1
  proxied = true
  comment = "CF tunnel for Cue API (CF Access: testers SSO + /health bypass + /ingest/healthkit service token)"
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
