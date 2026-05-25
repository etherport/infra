// User-tunable inputs for the Cloudflare module.

variable "cloudflare_account_id" {
  description = <<-EOT
    Cloudflare account ID. Find at https://dash.cloudflare.com → Workers & Pages → right sidebar shows "Account ID".
    Do NOT commit a real value to this file — pass via tfvars or workflow env var TF_VAR_cloudflare_account_id.
  EOT
  type        = string
}

variable "cf_subdomain" {
  description = "Subdomain to delegate to Cloudflare (e.g., wind.etherport.net)."
  type        = string
  default     = "wind.etherport.net"
}

variable "route53_parent_zone_name" {
  description = "The parent zone (in Route53) where the NS delegation record gets added."
  type        = string
  default     = "etherport.net"
}

variable "approval_hostname" {
  description = "FQDN for the AI advisor approval URL — gets a CF Access app + tunnel route."
  type        = string
  default     = "approve.wind.etherport.net"
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

variable "existing_wind_records" {
  description = <<-EOT
    Map of records to recreate inside Cloudflare for the wind.etherport.net zone, mirroring
    what currently exists in Route53. After NS delegation lands, these become the authoritative
    answers. Default proxied=false (DNS-only) so traffic still reaches existing origins
    unchanged. Switch to proxied=true per-record once you want the CF edge in the path.

    Values pre-filled from Route53 audit on 2026-05-25:
      wind apex    A     47.159.189.5         # home primary WAN IP (matches wan1)
      wan1         A     47.159.189.5         # DDNS lambda updates this — see note below
      wan2         A     66.215.210.75        # DDNS lambda updates this — see note below
      ceph         A     127.0.0.1            # ⚠ placeholder? probably wants real IP
      pve          A     127.0.0.1            # ⚠ placeholder? probably wants real IP
      ha           ALIAS dualstack.private-infra-alb-….amazonaws.com  # ALB alias (see below)
      *            ALIAS dualstack.private-infra-alb-….amazonaws.com  # ALB alias (see below)

    ALB aliases (ha + *): CF doesn't support AWS-style aliases. Two options when
    you're ready:
      1. CNAME to the ALB DNS name (keeps current routing through ALB)
      2. Drop the wildcard from CF; tunnel-route each `*.wind.etherport.net`
         service explicitly to its in-cluster service via a new entry in
         main.tf cloudflare_tunnel_config.config.ingress_rule[] +
         a CNAME to <tunnel>.cfargotunnel.com.
    Option 2 is the cost-saving end-state (drops the ALB once everything's
    tunneled). For now we ship Option 1 so cutover is non-breaking.

    DDNS lambda follow-up: infra/terraform/aws/ddns-lambda updates wan1/wan2
    in Route53. After NS delegation, Route53 writes become no-ops (CF is
    authoritative). The lambda needs to switch to writing CF DNS records.
    Tracked separately — see docs/runbooks/cloudflare-access-enable.md
    "DDNS lambda migration" section.

    ACME validation CNAMEs (_8e3818…wind.etherport.net.,
    _1ccc76b4…ha.wind.etherport.net.) MUST be carried over too so
    cert-manager can renew the wildcard + ha-specific certs. These are
    appended via existing_wind_acme_records below.
  EOT
  type = map(object({
    type    = string
    value   = string
    ttl     = optional(number, 300)
    proxied = optional(bool, false)
  }))
  default = {
    "@" = {
      type    = "A"
      value   = "47.159.189.5"   # home primary WAN
      proxied = false
    }
    "wan1" = {
      type    = "A"
      value   = "47.159.189.5"
      proxied = false
    }
    "wan2" = {
      type    = "A"
      value   = "66.215.210.75"
      proxied = false
    }
    # ⚠ ceph and pve point to 127.0.0.1 in Route53 — looks like a placeholder
    # left over from setup. Carried forward as-is so we don't change behavior
    # during the cutover. Replace with real values (or remove) before flipping
    # proxied=true on them.
    "ceph" = {
      type    = "A"
      value   = "127.0.0.1"
      proxied = false
    }
    "pve" = {
      type    = "A"
      value   = "127.0.0.1"
      proxied = false
    }
    # ALB aliases as CNAMEs (CF doesn't have AWS aliases). Same end-IP via
    # the ALB DNS lookup. Switch to tunnel-route + CNAME-to-cfargotunnel.com
    # per service when ready to drop the ALB.
    "ha" = {
      type    = "CNAME"
      value   = "dualstack.private-infra-alb-687735217.us-west-2.elb.amazonaws.com"
      proxied = false
    }
    "*" = {
      type    = "CNAME"
      value   = "dualstack.private-infra-alb-687735217.us-west-2.elb.amazonaws.com"
      proxied = false
    }
  }
}

variable "existing_wind_acme_records" {
  description = <<-EOT
    ACME validation CNAMEs for cert-manager's wildcard wind.etherport.net
    cert + the ha.wind.etherport.net cert. These MUST exist in whichever
    DNS is authoritative or cert renewals fail. Pre-filled from Route53
    audit 2026-05-25. CF zone names can contain dots so we use the bare
    label including the leading underscore + trailing zone-relative form.
  EOT
  type = map(object({
    type  = string
    value = string
    ttl   = optional(number, 300)
  }))
  default = {
    "_8e381876b8967e8fa6ba2c810f7c420c" = {
      type  = "CNAME"
      value = "_0d84538a58eaaee14b4e6fe7720c526d.jkddzztszm.acm-validations.aws."
    }
    "_1ccc76b4b2b06ff626fc1c649b61ab26.ha" = {
      type  = "CNAME"
      value = "_93aad1195f5deb9d8d22297d5166c990.jkddzztszm.acm-validations.aws."
    }
  }
}
