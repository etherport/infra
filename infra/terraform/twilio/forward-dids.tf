// 3 forwarding DIDs migrated off Twilio Studio (Flow FWba4e77be0b8a26120f1219a40fb123f0)
// onto the AWS Lambda webhook in infra/terraform/aws/twilio-webhook/.
//
// Behavior preserved from the old Studio flow:
//   voice → Lambda returns TwiML <Dial> to var.forward_target
//   SMS   → Lambda sends SES email to var.email_to recipient
//
// Decom of the Studio Flow + the email-aws-ses-1365.twil.io Twilio
// Function happens manually via the Twilio console once these DIDs
// are confirmed working on the Lambda path.

resource "twilio_api_accounts_incoming_phone_numbers" "forward" {
  for_each      = var.forward_dids
  phone_number  = each.value.phone_number
  friendly_name = each.value.friendly_name

  voice_url    = var.webhook_url
  voice_method = "POST"
  sms_url      = var.webhook_url
  sms_method   = "POST"

  // Studio set status_callback to itself; clearing it (we don't need
  // call-progress callbacks for a simple voice-forward use case).
  status_callback = ""

  lifecycle {
    ignore_changes = [
      voice_application_sid,
      sms_application_sid,
    ]
  }
}
