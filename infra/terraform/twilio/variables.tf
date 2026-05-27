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
    Currently sip:wind.gmsmeg.net:6767 — gmsmeg.net is a dead zone (no
    DNS), so inbound is silently broken. See #22 for the migration plan
    (target: sips:<new-host>:5061;transport=tls with sip_trunk_secure=true).
  EOT
  type        = string
  default     = "sip:wind.gmsmeg.net:6767"
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
