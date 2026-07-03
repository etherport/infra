variable "aws_profile" {
  description = "AWS profile to use (empty string for environment variables in CI)"
  type        = string
  default     = "homelab"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "hosted_zone_id" {
  description = <<-EOT
    DEPRECATED. The Lambda no longer uses Route53 — handler.py
    resolves records via public DNS (1.1.1.1 + 8.8.8.8 fallback)
    so it's zone-provider-agnostic. The HOSTED_ZONE_ID env var is
    still wired through main.tf but the Lambda accepts + ignores it.
    Empty default; drop the var entirely in a follow-up cleanup
    after a TF apply with it removed.
  EOT
  type        = string
  default     = ""
}

variable "security_group_id" {
  description = "DEPRECATED. Kept for backward compatibility with the previous single-SG variable. Use rule_specs instead."
  type        = string
  default     = "sg-08d12e417159c18d2"
}

variable "rule_specs" {
  description = "List of {security_group_id, port, protocols} tuples to manage. The Lambda keeps each SG's ingress rules for (port, protocols) in sync with the Route53 record IPs."
  type = list(object({
    security_group_id = string
    port              = number
    protocols         = list(string)
  }))
  default = [
    # dns_server SG: port 53 TCP+UDP (the original purpose).
    {
      security_group_id = "sg-08d12e417159c18d2"
      port              = 53
      protocols         = ["tcp", "udp"]
    },
    # allow_ssh SG: port 22 TCP. Enabled 2026-05-23 after user
    # confirmation that the stale entries (47.34.215.233 old "remote
    # location", 47.159.189.230 old TF var default, 146.70.238.13
    # + 146.70.238.0/24 NordVPN remnants, 86.98.93.115/32 UAE IP) are
    # all safe to drop. Lambda will reconcile to whatever wan1/wan2
    # currently resolve to. Note: /24 entries are out of scope (Lambda
    # only manages /32s) — those need manual cleanup.
    {
      security_group_id = "sg-0079fee23ee54417a"
      port              = 22
      protocols         = ["tcp"]
    },
    # vpn_server SG: wg0 site-to-site :51820 udp (F2, 2026-07-02, applied). The
    # old static 0.0.0.0/0 51820-51821 rule was split — 51821 (roaming remote
    # clients) stays world (static TF rule in aws/networking); 51820 (site-to-
    # site, only ever dialed from the homelab WANs) is Lambda-managed per-WAN
    # /32s so a WAN-IP change self-heals like :53/:22.
    {
      security_group_id = "sg-08323ff8e98ecb563"
      port              = 51820
      protocols         = ["udp"]
    },
  ]
}

variable "record_names" {
  description = "List of DNS record names to monitor for IP addresses"
  type        = list(string)
  default = [
    "wind.etherport.net",
    "wan1.wind.etherport.net",
    "wan2.wind.etherport.net"
  ]
}

variable "schedule_expression" {
  description = "EventBridge schedule expression for running the Lambda"
  type        = string
  default     = "rate(5 minutes)"
}

variable "lambda_memory" {
  description = "Lambda function memory in MB"
  type        = number
  default     = 128
}

variable "lambda_timeout" {
  description = "Lambda function timeout in seconds"
  type        = number
  default     = 30
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 30
}
