// User-tunable inputs for the Twilio module.

variable "primary_did" {
  description = <<-EOT
    The main Talk phone number (E.164 format, e.g. "+14155551234"). This is
    the DID that receives inbound calls AND is the source of outbound.
    Currently has the 911 emergency address issue (#20).
  EOT
  type        = string
}

variable "orphan_did_action" {
  description = <<-EOT
    Action for the unrouted DID (#21):
      "release"    — release the number (free monthly fee, number returned to pool)
      "route_voicemail" — point at a generic voicemail Studio flow
      "route_forward"  — forward to primary_did
    Default route_voicemail is safest — preserves the number while parking it.
  EOT
  type        = string
  default     = "route_voicemail"

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
}

variable "sip_trunk_friendly_name" {
  description = "Friendly name for the SIP trunk in Twilio console."
  type        = string
  default     = "Etherport Talk Trunk"
}

variable "sip_origination_url" {
  description = <<-EOT
    URI for inbound SIP routing — Twilio sends incoming calls here.
    For #22 (UDP→TLS+sRTP migration): use scheme `sips:` + secure trunk.
    Example: "sips:talk.wind.etherport.net:5061;transport=tls"
  EOT
  type        = string
}
