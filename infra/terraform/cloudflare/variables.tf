// User-tunable inputs for the Cloudflare module.

variable "cloudflare_account_id" {
  description = <<-EOT
    Cloudflare account ID. Find at https://dash.cloudflare.com → click your account in top-left
    → URL becomes https://dash.cloudflare.com/<32-hex-account-id> → that hex is your Account ID.
    Pass via TF_VAR_cloudflare_account_id (workflow env var) — do NOT commit a real value here.
  EOT
  type        = string
}

variable "cloudflare_zone_id" {
  description = <<-EOT
    Cloudflare Zone ID for the etherport.net zone. Zone is created manually via the CF dashboard
    ("+ Add a site" → etherport.net → Free) — CF Free doesn't allow API-based zone creation.
    After creation, grab the Zone ID from the zone overview page → API section.
    Pass via TF_VAR_cloudflare_zone_id.
  EOT
  type        = string
}

variable "cf_zone_domain" {
  description = "Full domain name of the CF zone (matches the manually-created zone)."
  type        = string
  default     = "etherport.net"
}

variable "approval_hostname" {
  description = <<-EOT
    FQDN for the AI advisor approval URL — gets a CF Access app + tunnel route.

    Note: kept at apex-level (`approve.etherport.net`) NOT under `wind.` because
    CF Universal SSL only covers root + one subdomain level for free. Two-deep
    hostnames (`*.wind.etherport.net`) would require Total TLS or ACM (paid).
    Apex-level subdomains get free per-hostname certs from Universal SSL.
  EOT
  type        = string
  default     = "approve.etherport.net"
}

variable "approval_origin_url" {
  description = <<-EOT
    Where cloudflared (running in-cluster) should send traffic after auth passes.
    Default points at the in-cluster Service for the auto-remediation webhook on its standard port.
    The cloudflared Deployment runs in the cloudflared namespace; cluster.local DNS resolves cross-namespace.
  EOT
  type        = string
  default     = "http://remediation-webhook.auto-remediation.svc.cluster.local:8080"
}

variable "allowed_emails" {
  description = "Email addresses allowed by the CF Access policy for the approval URL."
  type        = list(string)
  default     = ["grahamsm@gmail.com"]
}

variable "cf_tunnel_services" {
  description = <<-EOT
    Services exposed publicly via CF Tunnel + CF Access (Google SSO).

    Key: subdomain-relative-to-zone (e.g., "kopia.wind" becomes
         kopia.wind.etherport.net). Use the .wind. namespace for
         site-specific services. ACM on etherport.net + Total TLS
         provide free per-hostname certs for 2-level subdomains.

    Value: cluster_service_url = http://<svc>.<ns>.svc.cluster.local:<port>
           access_name        = friendly name shown in CF Access UI

    To add a service:
      1. Add an entry here
      2. terraform apply (creates CNAME + tunnel ingress + Access app + policy)
      3. (optional) Add Technitium A record for split-horizon LAN access
      4. (optional) Tighten origin's auth model — e.g., for Plex add the
         cloudflared pod CIDR (10.42.0.0/16) to "LAN Networks" so it
         treats tunnel traffic as local + skips its own login

    Legacy fallback: existing Traefik IngressRoutes at the same hostname
    keep functioning via the *.wind.etherport.net wildcard → ALB path.
    CF explicit records take precedence over the wildcard for external
    resolution.
  EOT
  type = map(object({
    cluster_service_url = string
    access_name         = string
  }))
  default = {
    "kopia.wind" = {
      cluster_service_url = "http://kopia.backups.svc.cluster.local:80"
      access_name         = "Kopia"
    }
    "technitium.wind" = {
      cluster_service_url = "http://technitium.dns.svc.cluster.local:5380"
      access_name         = "Technitium DNS"
    }
    "grafana.wind" = {
      cluster_service_url = "http://monitoring-grafana.monitoring.svc.cluster.local:80"
      access_name         = "Grafana"
    }
    "plex.wind" = {
      cluster_service_url = "http://plex.plex.svc.cluster.local:32400"
      access_name         = "Plex"
    }
    "ollama.wind" = {
      cluster_service_url = "http://ollama.ollama.svc.cluster.local:11434"
      access_name         = "Ollama API"
    }
    "chat.wind" = {
      cluster_service_url = "http://open-webui.ollama.svc.cluster.local:8080"
      access_name         = "Chat (Open-WebUI)"
    }
  }
}

variable "google_idp_id" {
  description = <<-EOT
    UUID of the Google SSO Identity Provider in the CF Zero Trust org. Required
    on the Access app when auto_redirect_to_identity = true. Find it via API
    (GET /accounts/{id}/access/identity_providers) or dashboard
    (Zero Trust → Settings → Authentication → click Google → URL has the UUID).
    Pretty stable infra — rotates roughly never.
  EOT
  type        = string
  default     = "d51942ea-5d8d-4fbf-8b57-8bfae2ea4ef5"
}

// ===========================================================================
// DNS records to recreate in CF zone, mirroring current Route53 state.
// Audit done 2026-05-25. Drop the 2 stale `wan1/wan2.etherport.net` (apex)
// records — they're not in lambda allowlist, not in TF, not in any active
// path. All other 20 records preserved exactly.
//
// Email-critical records (SES) are FIRST in each map for visibility. Test
// these end-to-end before declaring cutover success.
// ===========================================================================

variable "dns_records_a" {
  description = "A records to create in the etherport.net CF zone."
  type = map(object({
    value   = string
    ttl     = optional(number, 300)
    proxied = optional(bool, false)
    comment = optional(string, "")
  }))
  default = {
    // ---- DDNS-updated (post-cutover the K8s CronJob + ddns Lambda
    //      need to switch to writing CF DNS; static values until then) ----
    "wan1.wind" = {
      value   = "47.159.189.5"
      comment = "WAN1 IP — ddns-updater Lambda writes (Route53 today, CF post-migration)"
    }
    "wan2.wind" = {
      value   = "66.215.210.75"
      comment = "WAN2 IP — ddns-updater Lambda writes (Route53 today, CF post-migration)"
    }
    "wind" = {
      value   = "47.159.189.5"
      comment = "Active WAN — k8s route53-ddns CronJob writes every minute"
    }

    // ---- AWS VPN endpoints (static EIPs) ----
    "vpn-use1" = {
      value   = "35.169.37.16"
      comment = "AWS us-east-1 regional VPN EIP"
    }
    "vpn-usw2" = {
      value   = "44.240.60.80"
      comment = "AWS us-west-2 regional VPN EIP"
    }

    // ---- SIP trunk inbound (Twilio → UDM Talk) ----
    "sip.wind" = {
      value   = "47.159.189.5"
      comment = "Twilio Windtryst trunk → UDM Talk inbound (replaces dead sip:wind.gmsmeg.net)"
    }

    // ---- Internal-only sinkholes (resolve to loopback, preserve naming
    //      without leaking to public internet) ----
    "ceph.wind" = {
      value   = "127.0.0.1"
      comment = "Sinkhole — internal-only hostname, prevents accidental public access"
    }
    "pve.wind" = {
      value   = "127.0.0.1"
      comment = "Sinkhole — internal-only hostname, prevents accidental public access"
    }
  }
}

variable "dns_records_cname" {
  description = "CNAME records to create in the etherport.net CF zone."
  type = map(object({
    value   = string
    ttl     = optional(number, 300)
    proxied = optional(bool, false)
    comment = optional(string, "")
  }))
  default = {
    // ---- SES DKIM (email-critical — verify post-cutover with test send) ----
    "5gniifohq7dsyc2lphgcnx4j3a74ofco._domainkey" = {
      value   = "5gniifohq7dsyc2lphgcnx4j3a74ofco.dkim.amazonses.com"
      ttl     = 1800
      comment = "SES DKIM — email-critical"
    }
    "dy5wbhsewzcikzt45twscs2dl4g4vma2._domainkey" = {
      value   = "dy5wbhsewzcikzt45twscs2dl4g4vma2.dkim.amazonses.com"
      ttl     = 1800
      comment = "SES DKIM — email-critical"
    }
    "j5gqverli76qyzmlg6ulzs2ey36w6rgb._domainkey" = {
      value   = "j5gqverli76qyzmlg6ulzs2ey36w6rgb.dkim.amazonses.com"
      ttl     = 1800
      comment = "SES DKIM — email-critical"
    }

    // ---- ACME DNS-01 validation (cert-manager renewals depend on these) ----
    "_8e381876b8967e8fa6ba2c810f7c420c.wind" = {
      value   = "_0d84538a58eaaee14b4e6fe7720c526d.jkddzztszm.acm-validations.aws."
      comment = "ACME validation — wildcard *.wind.etherport.net cert (cert-manager renewals)"
    }
    "_1ccc76b4b2b06ff626fc1c649b61ab26.ha.wind" = {
      value   = "_93aad1195f5deb9d8d22297d5166c990.jkddzztszm.acm-validations.aws."
      comment = "ACME validation — ha.wind.etherport.net cert (cert-manager renewals)"
    }
    "_f6abe49fcaf7ee83c8013566f97ee85a" = {
      value   = "_2bab704205eefe6455fdb32fcc37c0c2.jkddzztszm.acm-validations.aws."
      comment = "ACME validation — apex etherport.net cert (cert-manager renewals)"
    }

    // Wildcard *.wind.etherport.net REMOVED 2026-05-27 — replaced by
    // VPN-only access (Tailscale + WireGuard) for the operator UIs that
    // were the last legitimate users of the ALB path. These hostnames
    // (pdu1/2, ups1/2, prox-ipmi, prox, switch1, traefik-dashboard) are
    // resolved internally via Technitium (see
    // platform/kubernetes/technitium/zones/wind.etherport.net.yaml) to
    // the Traefik LB IP (10.10.201.70). External DNS now returns NXDOMAIN
    // for these hostnames — they MUST be accessed via VPN.
    //
    // Decom order:
    //   1. Add missing Technitium A records (switch1, approve) — done.
    //   2. terraform apply this CF zone change — drops the wildcard.
    //   3. terraform destroy infra/terraform/aws/load-balancing/ —
    //      removes the ALB ($25/mo + transfer savings).
  }
}

variable "dns_records_mx" {
  description = "MX records — currently just the SES bounce/feedback endpoint."
  type = map(object({
    value    = string
    priority = number
    ttl      = optional(number, 300)
    comment  = optional(string, "")
  }))
  default = {
    "mail" = {
      value    = "feedback-smtp.us-west-2.amazonses.com"
      priority = 10
      comment  = "SES bounce/feedback receiver — email-critical"
    }
  }
}

variable "dns_records_txt" {
  description = "TXT records — SPF + DMARC for email auth."
  type = map(object({
    value   = string
    ttl     = optional(number, 300)
    comment = optional(string, "")
  }))
  default = {
    "mail" = {
      value   = "v=spf1 include:amazonses.com ~all"
      comment = "SPF for SES sender — email-critical"
    }
    "_dmarc" = {
      value   = "v=DMARC1; p=none;"
      comment = "DMARC policy — currently p=none (monitor only)"
    }
  }
}
