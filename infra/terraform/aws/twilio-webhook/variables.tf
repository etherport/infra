variable "aws_profile" {
  description = "AWS profile to use (empty string for env vars in CI)."
  type        = string
  default     = "homelab"
}

variable "forward_number" {
  description = <<-EOT
    E.164 phone number that inbound voice calls are forwarded to.
    Mirrors the old Twilio Studio "Connect Call To" widget.
  EOT
  type        = string
  default     = "+13108574182"
}

variable "email_to" {
  description = "Email address that incoming SMS gets forwarded to."
  type        = string
  default     = "grahamsm@gmail.com"
}

variable "ses_from" {
  description = <<-EOT
    SES sender address. Must be a verified identity in the SES region
    below. Uses the same etherport.net SES setup as the rest of the
    homelab (DKIM + SPF + DMARC already in CF DNS).
  EOT
  type        = string
  default     = "twilio-webhook@etherport.net"
}

variable "ses_region" {
  description = "AWS region where SES is configured (must match the Lambda region for in-region calls)."
  type        = string
  default     = "us-west-2"
}

variable "twilio_auth_token" {
  description = <<-EOT
    Twilio master Auth Token — used for X-Twilio-Signature webhook
    verification. Optional; if empty, the Lambda skips signature checks
    (less secure, but the URL is unguessable and Twilio's source IPs
    are the only ones reaching it in practice).

    Find at console.twilio.com → Account → API keys & tokens → Auth tokens.
    Pass via TF_VAR_twilio_auth_token in workflow; never commit.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}
