# twilio-webhook — voice forward + SMS → SES email

Replaces the legacy Twilio Studio Flow (`Fwd voice to mobile / SMS to email` —
`FWba4e77be0b8a26120f1219a40fb123f0`) + the old Twilio Function at
`email-aws-ses-1365.twil.io`. One AWS Lambda handles both via a single
Function URL.

## What it does

- **Voice call** → returns TwiML `<Response><Dial answerOnBridge="true">$FORWARD_NUMBER</Dial></Response>` → Twilio bridges to the forward number.
- **SMS** → calls SES `SendEmail` with HTML+text bodies → returns empty `<Response/>` (no auto-reply).

## Inputs (TF variables)

| Var | Default | Notes |
|---|---|---|
| `forward_number` | `+13108574182` | E.164 phone to dial on inbound voice |
| `email_to` | `grahamsm@gmail.com` | Recipient for SMS-to-email |
| `ses_from` | `twilio-webhook@etherport.net` | Must be a verified SES identity in `ses_region` |
| `ses_region` | `us-west-2` | Match Lambda region for in-region calls |
| `twilio_auth_token` | (empty) | Optional X-Twilio-Signature verification. `TF_VAR_twilio_auth_token` in CI |
| `aws_profile` | `homelab` | Empty string in CI |

## Outputs

- `function_url` — public HTTPS endpoint; set as DID `voice_url` + `sms_url`
- `function_arn`, `function_name`

## Deploy

```bash
cd infra/terraform/aws/twilio-webhook
terraform init
# Optional: pass auth token for signature verification (recommended)
TF_VAR_twilio_auth_token="$(op item get twilio-tf-api --fields password --reveal)" \
  terraform apply
terraform output -raw function_url
```

## Configure Twilio DIDs to use it

For each migrated DID, set both `voice_url` and `sms_url` to the function
URL via the Twilio TF module (`infra/terraform/twilio/`):

```hcl
# In the twilio module, add resources for the 3 Studio-bound DIDs:
resource "twilio_api_accounts_incoming_phone_numbers" "campaign_mobile" {
  phone_number  = "+19094308285"
  voice_url     = var.webhook_url
  voice_method  = "POST"
  sms_url       = var.webhook_url
  sms_method    = "POST"
  # ...
}
```

Pass `webhook_url` from this module's output via `terraform_remote_state`
or as a TF_VAR.

## Email design

Matches the homelab's other ops emails (see commit-trailers /
s3-sync daily-report modernization). Multipart text+html. CSS supports
dark mode via `prefers-color-scheme`. Stat row + body card + media list.

## Test (after deploy)

1. **Voice**: dial one of the migrated DIDs from any phone. Expect call to bridge to `forward_number`.
2. **SMS**: text one of the migrated DIDs. Expect email arrives at `email_to` within ~5s, with the SMS contents formatted in the modern template.
3. **CloudWatch logs**: `aws --profile homelab --region us-west-2 logs tail /aws/lambda/twilio-webhook --follow`.

## Security notes

- **X-Twilio-Signature**: enable by setting `TWILIO_AUTH_TOKEN`. Without it, anyone who learns the Function URL could POST arbitrary "SMS" to spoof emails. URL is unguessable but not secret.
- **Function URL `authorization_type = NONE`** — Twilio doesn't carry AWS SigV4. Auth is via the signature header.
- **SES sender** must be verified in the region. Use a sender on `etherport.net` so SPF/DKIM/DMARC (already configured in CF DNS) pass.

## Rotation

Twilio auth token rotation (if `TWILIO_AUTH_TOKEN` is set):
1. Console → Account → API keys & tokens → Auth tokens → rotate primary
2. `TF_VAR_twilio_auth_token=<new> terraform apply` (re-deploys Lambda with new token)
3. After verifying, deactivate the old token

## What this replaces (decom plan)

After all 3 DIDs (campaign, UK, US personal) are pointing at this Lambda
+ verified working:

1. In Twilio console → Studio → Flows → `FWba4e77be0b8a26120f1219a40fb123f0` → delete (or archive)
2. Twilio Functions → `email-aws-ses-1365.twil.io` service → delete
3. Removes the last non-IaC pieces of the Talk infra
