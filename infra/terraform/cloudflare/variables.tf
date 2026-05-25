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
    answers. Set proxied=false initially (DNS-only) so traffic still reaches existing origins
    unchanged. Switch to proxied=true per-record once you want the CF edge in the path.
  EOT
  type = map(object({
    type    = string
    value   = string
    ttl     = optional(number, 300)
    proxied = optional(bool, false)
  }))
  default = {
    # Apex of the subdomain — currently pointing at home WAN IP (Route53 A record).
    # The value here will be filled in from the actual current A record value during
    # apply (see post-init step in the runbook).
    "@" = {
      type    = "A"
      value   = "REPLACE_WITH_CURRENT_A_RECORD_VALUE"
      proxied = false
    }
    "wan1" = {
      type    = "A"
      value   = "REPLACE_WITH_CURRENT_A_RECORD_VALUE"
      proxied = false
    }
    "wan2" = {
      type    = "A"
      value   = "REPLACE_WITH_CURRENT_A_RECORD_VALUE"
      proxied = false
    }
    "ceph" = {
      type    = "A"
      value   = "REPLACE_WITH_CURRENT_A_RECORD_VALUE"
      proxied = false
    }
    "ha" = {
      type    = "A"
      value   = "REPLACE_WITH_CURRENT_A_RECORD_VALUE"
      proxied = false
    }
    "pve" = {
      type    = "A"
      value   = "REPLACE_WITH_CURRENT_A_RECORD_VALUE"
      proxied = false
    }
    # Wildcard A — ALB or other LB target. Will need value from current Route53.
    "*" = {
      type    = "A"
      value   = "REPLACE_WITH_CURRENT_WILDCARD_A_VALUE"
      proxied = false
    }
  }
}
