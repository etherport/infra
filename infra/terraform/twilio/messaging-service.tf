// Messaging Service — uniform inbound SMS routing for ALL Talk numbers.
//
// Twilio's recommended pattern for inbound SMS: one Messaging Service whose
// inbound webhook is the shared AWS Lambda (var.webhook_url), with every number
// added as a sender. This ALSO sidesteps the E911 lock (ApiError 21631) that
// blocks a direct sms_url change on the primary/SIP DID — adding a number to a
// Messaging Service doesn't touch the number's emergency-locked config.
//
// use_inbound_webhook_on_number = false → the SERVICE's webhook handles inbound
// SMS for every member number (their per-number sms_url is bypassed). The
// forward DIDs keep sms_url = var.webhook_url as harmless redundancy (same
// Lambda); the primary DID never had a managed sms_url. Result: all numbers
// route inbound SMS the same way — service → Lambda.

resource "twilio_messaging_services_v1" "talk" {
  friendly_name                 = "Talk Inbound SMS"
  inbound_request_url           = var.webhook_url
  inbound_method                = "POST"
  use_inbound_webhook_on_number = false
}

// Primary / SIP DID (+19094142433, carries the E911 address) — inbound SMS now
// flows via the service → Lambda, replacing the Studio Flow, without an
// emergency-address-locked number update.
resource "twilio_messaging_services_phone_numbers_v1" "primary" {
  service_sid      = twilio_messaging_services_v1.talk.sid
  phone_number_sid = twilio_api_accounts_incoming_phone_numbers.primary.sid
}

// Forward DIDs — same service, for uniform routing.
resource "twilio_messaging_services_phone_numbers_v1" "forward" {
  for_each         = var.forward_dids
  service_sid      = twilio_messaging_services_v1.talk.sid
  phone_number_sid = twilio_api_accounts_incoming_phone_numbers.forward[each.key].sid
}

output "messaging_service_sid" {
  description = "Talk Inbound SMS Messaging Service SID (all DIDs route SMS through it)."
  value       = twilio_messaging_services_v1.talk.sid
}
