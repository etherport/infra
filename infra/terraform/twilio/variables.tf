// User-tunable inputs for the Twilio module.

variable "primary_did" {
  description = <<-EOT
    The main Talk phone number (E.164 format). DID that receives inbound
    calls AND is the source of outbound via the Windtryst SIP trunk.
    Already has emergency_address_status=registered (preserved across
    the 2026-05-26 1003 release + 2026-05-27 TF re-import).
  EOT
  type        = string
  default     = "+19094142433"
}

variable "orphan_did_action" {
  description = <<-EOT
    Action for the unrouted DID (#21):
      "release"    — release the number (no resource managed; default)
      "route_voicemail" — point at a generic voicemail Studio flow
      "route_forward"  — forward to primary_did
    Default "release" matches current state: +19094141003 was released
    2026-05-26 via Twilio Python SDK (see docs/runbooks/twilio-talk.md).
  EOT
  type        = string
  default     = "release"

  validation {
    condition     = contains(["release", "route_voicemail", "route_forward"], var.orphan_did_action)
    error_message = "orphan_did_action must be one of: release, route_voicemail, route_forward"
  }
}

variable "orphan_did_sid" {
  description = "SID of the orphan DID (PNxxxxx...) — discovered + filled in after first import."
  type        = string
  default     = ""
}

variable "emergency_address" {
  description = "911 emergency address attached to the primary DID (#20)."
  type = object({
    friendly_name    = string
    customer_name    = string
    street           = string
    city             = string
    region           = string   # state code (e.g., "WA")
    postal_code      = string
    iso_country      = string   # 2-letter country code (e.g., "US")
    street_secondary = optional(string, "")
  })
  default = {
    friendly_name = "Cabin"
    customer_name = "Smith"
    street        = "843 GREENBRIAR DR"
    city          = "SKYFOREST"
    region        = "CA"
    postal_code   = "92385"
    iso_country   = "US"
  }
}

variable "sip_trunk_friendly_name" {
  description = "Friendly name for the SIP trunk in Twilio console."
  type        = string
  default     = "Windtryst"
}

variable "sip_trunk_secure" {
  description = <<-EOT
    When true, the SIP trunk requires TLS for signaling + sRTP for media.
    Set to false until the SIP endpoint (sip_origination_url) is TLS-ready,
    otherwise inbound calls break. See #22 for the migration.
  EOT
  type        = bool
  default     = false
}

variable "sip_origination_url" {
  description = <<-EOT
    URI for inbound SIP routing — Twilio sends incoming calls here.
    Migrated 2026-05-27 from dead sip:wind.gmsmeg.net:6767 to
    sips:sip.wind.etherport.net:5061;transport=tls. The hostname is a
    CF DNS A record pointing at the UDM WAN IP (47.159.189.5).

    Uses `sips:` scheme for TLS-encrypted signaling. sip_trunk_secure
    stays false (no Twilio Secure Trunking) because UniFi Talk doesn't
    support sRTP — Twilio would reject calls under full secure mode.
    Plan: revisit when Ubiquiti ships sRTP, or insert an SBC (task #80).
  EOT
  type        = string
  default     = "sips:sip.wind.etherport.net:5061;transport=tls"
}

variable "sip_origination_friendly_name" {
  description = "Friendly name for the origination URL row in the trunk console (currently null)."
  type        = string
  default     = ""
}

variable "sip_origination_weight" {
  description = "Origination URL weight (load balancing among multiple origination URLs). Currently 10."
  type        = number
  default     = 10
}

variable "sip_origination_priority" {
  description = "Origination URL priority. Currently 10 (lower = higher priority, but only one URL exists so it's moot)."
  type        = number
  default     = 10
}

variable "webhook_url" {
  description = <<-EOT
    AWS Lambda Function URL that handles inbound voice + SMS for the
    forwarding DIDs (see forward-dids.tf). Replaces the legacy Twilio
    Studio Flow FWba4e77be0b8a26120f1219a40fb123f0.

    Sourced from `terraform output -raw function_url` in the
    infra/terraform/aws/twilio-webhook/ module.
  EOT
  type        = string
  default     = "https://l5afpm7ybw3x3o6vslb3sma3ui0ngeel.lambda-url.us-west-2.on.aws/"
}

variable "forward_dids" {
  description = <<-EOT
    Map of DIDs that use the simple forward-voice + SMS-to-email
    pattern (Lambda-backed). Originally on Studio Flow; migrated
    2026-05-27.
  EOT
  type = map(object({
    phone_number  = string
    friendly_name = string
  }))
  default = {
    campaign = {
      phone_number  = "+19094308285"
      friendly_name = "Campaign mobile"
    }
    uk = {
      phone_number  = "+447545911500"
      friendly_name = "Graham UK Mobile"
    }
    us_personal = {
      phone_number  = "+14246257334"
      friendly_name = "Graham US personal"
    }
  }
}
