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

variable "tfstate_bucket" {
  description = "S3 Terraform state bucket the mini RA role may read/write (for local `terraform plan`/state ops). All other object/secret reads are denied."
  type        = string
  default     = "terraform.wind.etherport.net"
}
