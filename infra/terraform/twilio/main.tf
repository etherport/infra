// Twilio Talk infrastructure — DIDs, emergency address, SIP trunk.
//
// Scope: only what the user actually uses (Programmable Voice + SIP
// trunking for the Talk system). NOT in scope: Studio flows (visual,
// not well-suited to TF), TaskRouter, IP Messaging.
//
// Workflow:
//   1. User creates API Key in Twilio console (one-time) per README.
//   2. terraform import <each existing DID + trunk + addresses> into
//      state — see README "Initial import" for exact commands.
//   3. terraform plan should show ZERO changes after a clean import
//      (sanity that TF matches reality).
//   4. Then edit variables.tf to land the 3 outstanding fixes:
//      #20  emergency_address  → applies new Address + binds to primary DID
//      #21  orphan_did_action  → release OR route the unrouted DID
//      #22  sip_origination_url with `sips:` scheme + secure=true on trunk

// ---------------------------------------------------------------------------
// Emergency address — task #20
// Twilio resource for emergency dispatch routing. When a 911 call originates
// from a number with this address attached, the address is what EMS uses
// to find the caller.
// ---------------------------------------------------------------------------
resource "twilio_api_accounts_addresses_v2010" "primary" {
  friendly_name    = var.emergency_address.friendly_name
  customer_name    = var.emergency_address.customer_name
  street           = var.emergency_address.street
  street_secondary = var.emergency_address.street_secondary
  city             = var.emergency_address.city
  region           = var.emergency_address.region
  postal_code      = var.emergency_address.postal_code
  iso_country      = var.emergency_address.iso_country
  emergency_enabled = true
}

// ---------------------------------------------------------------------------
// Primary DID — attach the emergency address.
// To IMPORT: terraform import twilio_api_accounts_incoming_phone_numbers_v2010.primary <PN-sid>
//   (find the SID in console → Phone Numbers → Active Numbers → click number → "Number SID")
// ---------------------------------------------------------------------------
resource "twilio_api_accounts_incoming_phone_numbers_v2010" "primary" {
  phone_number          = var.primary_did
  address_sid           = twilio_api_accounts_addresses_v2010.primary.sid
  emergency_status      = "Active"
  emergency_address_sid = twilio_api_accounts_addresses_v2010.primary.sid

  // After import, these fields will be set to current values — drop
  // any here that you don't want TF to manage / will manually tune
  // in console. Common ones intentionally NOT in TF for now:
  //   voice_url, voice_method, voice_fallback_url, sms_url, status_callback
  //   (these usually point at Studio flows or Twilio Functions, which
  //   are operator-tuned. Add to TF only if you want declarative control.)

  lifecycle {
    ignore_changes = [
      // Tags Twilio adds that aren't part of our intent
      voice_application_sid,
      sms_application_sid,
    ]
  }
}

// ---------------------------------------------------------------------------
// Orphan DID — task #21
// ---------------------------------------------------------------------------
// Decision lives in variables.orphan_did_action:
//   "release"        — removed from this TF (operator deletes from console)
//   "route_voicemail" — points at a generic-voicemail TwiML Bin
//   "route_forward"   — forwards to primary_did via TwiML
//
// "release" path: don't define the resource at all → no TF management.
// "route_voicemail" / "route_forward": import + manage voice_url.

resource "twilio_api_accounts_incoming_phone_numbers_v2010" "orphan" {
  count = var.orphan_did_action == "release" ? 0 : 1

  // SID-only attach (no phone_number on import lookup)
  phone_number = "" // populated from import

  voice_url = (
    var.orphan_did_action == "route_voicemail"
      ? "https://handler.twilio.com/twiml/EH00000000000000000000000000000000" // PLACEHOLDER — replace with real Studio flow or TwiML Bin URL
      : "https://handler.twilio.com/twiml/EH11111111111111111111111111111111" // PLACEHOLDER — replace with forward-to-primary TwiML
  )
  voice_method = "POST"

  lifecycle {
    ignore_changes = [phone_number]
  }
}

// ---------------------------------------------------------------------------
// SIP Trunk — task #22
// ---------------------------------------------------------------------------
// secure=true forces TLS for signaling + sRTP for media. Combined with
// the sips: scheme in origination URL, this fully encrypts the call.
// Pre-migration: UDP + RTP. Post-migration: TLS + sRTP.
resource "twilio_trunking_trunks_v1" "talk" {
  friendly_name = var.sip_trunk_friendly_name
  secure        = true // TLS signaling + sRTP media
}

resource "twilio_trunking_origination_urls_v1" "talk_primary" {
  trunk_sid    = twilio_trunking_trunks_v1.talk.sid
  friendly_name = "primary (sips/tls)"
  sip_url      = var.sip_origination_url   // expect "sips:host:5061;transport=tls"
  weight       = 10
  priority     = 1
  enabled      = true
}
