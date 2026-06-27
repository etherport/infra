variable "aws_region" {
  description = "AWS region for the Roles Anywhere trust anchor/profile/role"
  type        = string
  default     = "us-west-2"
}

variable "aws_profile" {
  description = "Local AWS profile (set to \"\" in CI — OIDC role is assumed instead)"
  type        = string
  default     = "homelab"
}

variable "account_id" {
  description = "AWS account ID"
  type        = string
  default     = "830881980142"
}

variable "trust_anchor_cert_file" {
  description = "Path to the step-ca ROOT CA cert PEM used as the RA trust anchor (public cert; committed)"
  type        = string
  default     = "step-ca-root.pem"
}

variable "mini_cert_cn" {
  description = <<-EOT
    The exact X.509 Subject CN that step-ca will put on the mini's RA client cert.
    The IAM role trust policy is scoped to this CN — only a step-ca-issued cert with
    this CN can assume the role. Must match what the mini-side runbook mints.
  EOT
  type        = string
  default     = "mini.wind.etherport.net"
}

variable "session_duration_seconds" {
  description = "Max RA session length (STS creds TTL). 3600 = 1h."
  type        = number
  default     = 3600
}

variable "mini_cert_issuer_cn" {
  description = <<-EOT
    Defense-in-depth: also require the client cert's ISSUER Subject CN to equal this
    (so only certs issued by THIS step-ca intermediate — not any cert chaining to the
    root — can assume the role). Default = the step-ca intermediate CN. Set to "" to
    disable the issuer condition (CN + trust-anchor scoping then stand alone).
  EOT
  type        = string
  default     = "wind Homelab CA Intermediate CA"
}

variable "attached_policy_names" {
  description = <<-EOT
    Customer-managed IAM policy NAMES to attach to the mini's RA role (resolved to
    arn:aws:iam::<account_id>:policy/<name>). ⚠️ DECISION (see m71-roles-anywhere-plan.md
    §"three owner-gated steps" #2):
      * Default below = FULL parity with terraform-homelab (~20 policies) → REQUIRES raising
        the per-role managed-policy quota (Service Quotas L-0DA4ABF3, default 10, max 20)
        BEFORE apply, or apply fails with LimitExceeded.
      * Or trim to a ≤10 curated subset (TF is CI-only since M82 — the mini's local TF is
        rare debug, so a state+read+the-few-stacks-you-debug subset is defensible).
    ⚠️ The agent derived these names from the iam-policies/terraform-*.json filenames (README
    says they match AWS policy names). CONFIRM against the account before apply:
      aws iam list-attached-user-policies --user-name terraform-homelab   (from claude-admin)
      aws iam list-groups-for-user --user-name terraform-homelab  +  list-attached-group-policies
  EOT
  type        = list(string)
  default = [
    "terraform-storage",
    "terraform-compute",
    "terraform-networking",
    "terraform-dns",
    "terraform-dns-restrict-ip",
    "terraform-cloudfront",
    "terraform-twilio-webhook",
    "terraform-state",
    "terraform-iam-users",
    "terraform-lambda-manage",
    "terraform-snapshot-archive",
    "terraform-ec2-security-groups",
    "terraform-email-forward",
    "terraform-eventbridge",
    "terraform-external-monitoring",
    "terraform-homeassistant-alexa",
    "terraform-ddns-core",
    "terraform-ddns-logs",
    "terraform-ddns-secrets-iam",
    "terraform-ddns-state",
  ]
}
