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

variable "s3_bucket_name" {
  description = <<-EOT
    S3 bucket name for email storage. Bucket lives in this AWS account
    (managed by infra/terraform/aws/s3); name is grandfathered from
    when grahamsmith.net was a homelab-managed zone (pre 2026-05-27).
    Rename not worth the churn — the bucket name has no functional
    meaning to consumers.
  EOT
  type        = string
  default     = "email-fwd.grahamsmith.net"
}

variable "verified_sender" {
  description = <<-EOT
    Verified SES sender email address. The grahamsmith.net SES
    identity is now managed in the personal-web repo
    (terraform/ses-email-forward); this default refers to that
    identity. Keep in sync if the identity moves.
  EOT
  type        = string
  default     = "g@grahamsmith.net"
}

variable "graham_forward_to" {
  description = "Email address to forward graham's emails to"
  type        = string
  default     = "grahamsm@gmail.com"
}

