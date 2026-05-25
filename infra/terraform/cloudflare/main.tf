// Cloudflare Tunnel + Access for the AI advisor approval URL (and any
// future *.wind.etherport.net public-with-auth services).
//
// Architecture:
//   1. CF zone `wind.etherport.net` (this module owns it)
//   2. Route53 etherport.net adds NS records delegating wind.etherport.net
//      to CF nameservers (so CF becomes authoritative for *.wind.etherport.net)
//   3. CF zone recreates existing wind.etherport.net A records (currently in
//      Route53) so service hosts stay reachable post-delegation
//   4. Cloudflare Tunnel `wind-cluster` runs as `cloudflared` Deployment in
//      the cluster (no inbound ports — outbound TLS to CF only)
//   5. `approve.wind.etherport.net` CNAME → `<tunnel-id>.cfargotunnel.com`
//   6. CF Access Application on that hostname requires Google SSO
//   7. CF Access Policy allows only `allowed_emails`
//
// After apply, the workflow surfaces the tunnel TOKEN — feed it into the
// k8s SOPS secret `platform/kubernetes/cloudflared/01-tunnel-token.sops.yaml`.
//
// SAFETY: This module does NOT apply the Route53 NS delegation step
// automatically. The delegation is the destructive change (it cuts over
// authoritative DNS). Module produces the NS values as outputs; user does
// a separate Route53 PR to add them when ready.

// ---------------------------------------------------------------------------
// 1. Cloudflare zone — wind.etherport.net
// ---------------------------------------------------------------------------
resource "cloudflare_zone" "wind" {
  account_id = var.cloudflare_account_id
  zone       = var.cf_subdomain
  plan       = "free"
  type       = "full"
}

// ---------------------------------------------------------------------------
// 2. Recreate existing wind.etherport.net records inside CF.
//    Values come from variables.tf (user fills from current Route53 state).
//    Until NS delegation flips, these records exist in CF but are ignored
//    by resolvers — Route53 is still authoritative. After delegation, CF
//    answers — having the same A values means no service interruption.
// ---------------------------------------------------------------------------
resource "cloudflare_record" "wind_existing" {
  for_each = var.existing_wind_records

  zone_id = cloudflare_zone.wind.id
  name    = each.key
  type    = each.value.type
  value   = each.value.value
  ttl     = each.value.ttl
  proxied = each.value.proxied
  comment = "Mirrored from Route53 (pre-delegation). Set proxied=true to put CF edge in path."
}

// ---------------------------------------------------------------------------
// 3. Cloudflare Tunnel — the bridge from cluster to CF edge.
//    Tunnel secret is generated locally + passed into the tunnel resource.
//    The secret + tunnel_id together form the TUNNEL_TOKEN that cloudflared
//    daemon needs. We emit a sensitive output containing the token so the
//    user can sops-edit it into platform/kubernetes/cloudflared/.
// ---------------------------------------------------------------------------
resource "random_id" "tunnel_secret" {
  byte_length = 35  # CF docs recommend ≥32 bytes
}

resource "cloudflare_tunnel" "wind_cluster" {
  account_id = var.cloudflare_account_id
  name       = "wind-cluster"
  secret     = random_id.tunnel_secret.b64_std
}

// ---------------------------------------------------------------------------
// 4. Tunnel ingress configuration — declarative routing inside the tunnel
//    so cloudflared knows what hostname maps to what origin.
//    Future hostnames added to the tunnel only need a new ingress entry +
//    a CNAME record (below) + a CF Access app.
// ---------------------------------------------------------------------------
resource "cloudflare_tunnel_config" "wind_cluster" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_tunnel.wind_cluster.id

  config {
    // approve.wind.etherport.net → in-cluster auto-remediation webhook
    ingress_rule {
      hostname = var.approval_hostname
      service  = var.approval_origin_url
      origin_request {
        // Webhook is plain HTTP inside the cluster; no TLS-to-origin needed.
        no_tls_verify = false
        connect_timeout = "10s"
      }
    }
    // Catch-all required by cloudflared.
    ingress_rule {
      service = "http_status:404"
    }
  }
}

// ---------------------------------------------------------------------------
// 5. CNAME for approve.wind.etherport.net → tunnel
// ---------------------------------------------------------------------------
resource "cloudflare_record" "approve_cname" {
  zone_id = cloudflare_zone.wind.id
  name    = split(".", var.approval_hostname)[0]   # "approve" — record name is relative to zone
  type    = "CNAME"
  value   = "${cloudflare_tunnel.wind_cluster.id}.cfargotunnel.com"
  ttl     = 1     # 1 = auto when proxied
  proxied = true  # required for CF Access to intercept
  comment = "CF tunnel for AI advisor approval URL (CF Access in front)"
}

// ---------------------------------------------------------------------------
// 6. CF Access Application — gates the approval URL
// ---------------------------------------------------------------------------
resource "cloudflare_zero_trust_access_application" "approve" {
  account_id                 = var.cloudflare_account_id
  name                       = "AI Advisor Approval URL"
  domain                     = var.approval_hostname
  type                       = "self_hosted"
  session_duration           = "24h"
  app_launcher_visible       = false
  auto_redirect_to_identity  = true
}

// ---------------------------------------------------------------------------
// 7. CF Access Policy — allow only specified emails
//    Identity provider chosen at the dashboard level; "Google" can be added
//    via cloudflare_zero_trust_access_identity_provider but Google SSO works
//    out-of-the-box via CF's built-in providers without any TF setup.
// ---------------------------------------------------------------------------
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
// NOTE: Route53 NS delegation is NOT in this module.
// See outputs.tf for the NS values; add them by hand to
// infra/terraform/aws/route53/records-etherport.tf when ready to cut over.
// ---------------------------------------------------------------------------
