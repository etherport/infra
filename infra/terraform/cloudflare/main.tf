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
//   - The two ddns writers (ddns-updater Lambda + route53-ddns CronJob)
//     get rewritten to use CF DNS API post-cutover (see runbook)

// ---------------------------------------------------------------------------
// 1. Cloudflare zone — imported (NOT created — see top-of-file).
//    To import: `terraform import cloudflare_zone.etherport <zone-id>` after
//    creating the zone in the CF dashboard.
// ---------------------------------------------------------------------------
resource "cloudflare_zone" "etherport" {
  account_id = var.cloudflare_account_id
  zone       = var.cf_zone_domain
  plan       = "free"
  type       = "full"

  // Don't allow accidental TF destroy of the zone — that would delete all
  // records + break DNS authority. Manual cleanup in the dashboard if ever
  // truly needed.
  lifecycle {
    prevent_destroy = true
  }
}

// ---------------------------------------------------------------------------
// 2. DNS records — A, CNAME, MX, TXT.
//    Each resource block uses for_each over the corresponding variable map
//    so adding a new record is a one-line change in variables.tf.
// ---------------------------------------------------------------------------

resource "cloudflare_record" "a" {
  for_each = var.dns_records_a

  zone_id = var.cloudflare_zone_id
  name    = each.key
  type    = "A"
  value   = each.value.value
  ttl     = each.value.ttl
  proxied = each.value.proxied
  comment = each.value.comment
  # CF auto-creates default records on zone create (e.g. mail MX) — let TF
  # overwrite them instead of conflicting. We're the source of truth.
  allow_overwrite = true
}

resource "cloudflare_record" "cname" {
  for_each = var.dns_records_cname

  zone_id = var.cloudflare_zone_id
  name    = each.key
  type    = "CNAME"
  value   = each.value.value
  ttl     = each.value.ttl
  proxied = each.value.proxied
  comment = each.value.comment
  # CF auto-creates default records on zone create (e.g. mail MX) — let TF
  # overwrite them instead of conflicting. We're the source of truth.
  allow_overwrite = true
}

resource "cloudflare_record" "mx" {
  for_each = var.dns_records_mx

  zone_id         = var.cloudflare_zone_id
  name            = each.key
  type            = "MX"
  value           = each.value.value
  priority        = each.value.priority
  ttl             = each.value.ttl
  comment         = each.value.comment
  allow_overwrite = true
}

resource "cloudflare_record" "txt" {
  for_each = var.dns_records_txt

  zone_id         = var.cloudflare_zone_id
  name            = each.key
  type            = "TXT"
  value           = each.value.value
  ttl             = each.value.ttl
  comment         = each.value.comment
  allow_overwrite = true
}

// ---------------------------------------------------------------------------
// 3. Cloudflare Tunnel — the bridge from cluster to CF edge.
//    Secret generated locally → combined with tunnel_id forms TUNNEL_TOKEN
//    that cloudflared daemon needs. Emit as sensitive output for sops-edit.
// ---------------------------------------------------------------------------
resource "random_id" "tunnel_secret" {
  byte_length = 35
}

resource "cloudflare_tunnel" "wind_cluster" {
  account_id = var.cloudflare_account_id
  name       = "wind-cluster"
  secret     = random_id.tunnel_secret.b64_std
}

// ---------------------------------------------------------------------------
// 4. Tunnel ingress configuration — declarative routing inside the tunnel.
// ---------------------------------------------------------------------------
resource "cloudflare_tunnel_config" "wind_cluster" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_tunnel.wind_cluster.id

  config {
    ingress_rule {
      hostname = var.approval_hostname
      service  = var.approval_origin_url
      origin_request {
        no_tls_verify   = false
        connect_timeout = "10s"
      }
    }
    // wiki-js — first migration off the AWS ALB / Traefik public path
    // (2026-05-26). Traefik IngressRoute at wiki.wind.etherport.net is
    // retained as split-horizon fallback for VPN/local access; this CF
    // path is the primary external route, gated by CF Access (Google SSO).
    ingress_rule {
      hostname = "wiki.etherport.net"
      service  = "http://wiki-js.wikijs.svc.cluster.local:3000"
      origin_request {
        no_tls_verify   = false
        connect_timeout = "10s"
      }
    }
    // Catch-all required by cloudflared
    ingress_rule {
      service = "http_status:404"
    }
  }
}

// ---------------------------------------------------------------------------
// 5. CNAME for approve.etherport.net → tunnel
//    Apex-level subdomain ("approve" relative to etherport.net zone), so the
//    free Universal SSL cert (covers root + *.etherport.net) handles TLS.
//    Two-deep hostnames like approve.etherport.net would have needed
//    paid Total TLS / ACM.
// ---------------------------------------------------------------------------
resource "cloudflare_record" "approve_cname" {
  zone_id = var.cloudflare_zone_id
  name    = "approve"
  type    = "CNAME"
  value   = "${cloudflare_tunnel.wind_cluster.id}.cfargotunnel.com"
  ttl     = 1    # 1 = auto when proxied
  proxied = true # required for CF Access to intercept
  comment = "CF tunnel for AI advisor approval URL (CF Access in front)"
}

// ---------------------------------------------------------------------------
// 6 + 7. CF Access Application + Policy — gates the approval URL
//
// Uncommented 2026-05-26 after etherport.net NS flip completed and the CF
// zone went Active. CF Access validates `domain` against zones in your
// account and would reject ("domain does not belong to zone (12130)")
// while the zone is in Pending Nameserver Update — that gate is now passed.

resource "cloudflare_zero_trust_access_application" "approve" {
  account_id                = var.cloudflare_account_id
  name                      = "AI Advisor Approval URL"
  domain                    = var.approval_hostname
  type                      = "self_hosted"
  session_duration          = "24h"
  app_launcher_visible      = false
  auto_redirect_to_identity = true
  allowed_idps              = [var.google_idp_id]
}

resource "cloudflare_zero_trust_access_policy" "approve_allow" {
  account_id     = var.cloudflare_account_id
  application_id = cloudflare_zero_trust_access_application.approve.id
  name           = "Allow listed emails"
  precedence     = 1
  decision       = "allow"

  include {
    email = var.allowed_emails
  }
}

// ---------------------------------------------------------------------------
// wiki-js — first ALB → CF Tunnel migration.
//
// Pattern (mirror of approve.* above):
//   - CNAME wiki.etherport.net → tunnel (proxied for CF Access interception)
//   - Access Application with self_hosted type + Google IdP
//   - Access Policy allowing listed emails
//
// The matching ingress_rule lives in cloudflare_tunnel_config.wind_cluster
// above. Origin is the in-cluster wiki-js Service (ClusterIP).
//
// Split-horizon fallback: the existing Traefik IngressRoute at
// wiki.wind.etherport.net stays untouched. VPN/local clients resolve
// wiki.etherport.net to the internal Traefik LB via Technitium so the
// same URL works both on + off CF.
// ---------------------------------------------------------------------------
resource "cloudflare_record" "wiki_cname" {
  zone_id = var.cloudflare_zone_id
  name    = "wiki"
  type    = "CNAME"
  value   = "${cloudflare_tunnel.wind_cluster.id}.cfargotunnel.com"
  ttl     = 1
  proxied = true
  comment = "CF tunnel for wiki-js (CF Access in front)"
}

resource "cloudflare_zero_trust_access_application" "wiki" {
  account_id                = var.cloudflare_account_id
  name                      = "Wiki.js"
  domain                    = "wiki.etherport.net"
  type                      = "self_hosted"
  session_duration          = "24h"
  app_launcher_visible      = true
  auto_redirect_to_identity = true
  allowed_idps              = [var.google_idp_id]
}

resource "cloudflare_zero_trust_access_policy" "wiki_allow" {
  account_id     = var.cloudflare_account_id
  application_id = cloudflare_zero_trust_access_application.wiki.id
  name           = "Allow listed emails"
  precedence     = 1
  decision       = "allow"

  include {
    email = var.allowed_emails
  }
}
