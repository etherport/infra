# Twilio Talk — Terraform module

Brings the Twilio Programmable Voice + SIP trunk setup under IaC, and
turns the 3 pending Talk tasks into TF apply'd changes:

| Task | Resolution path |
|---|---|
| #20 fix 911 emergency address | New `twilio_api_accounts_addresses_v2010` resource + bound to primary DID via `emergency_address_sid` |
| #21 route or release orphan DID | `orphan_did_action` variable: `release`, `route_voicemail`, or `route_forward` |
| #22 migrate SIP trunk UDP→TLS+sRTP | `twilio_trunking_trunks_v1.secure = true` + `sips:` scheme in origination URL |

## Prerequisites (one-time, ~5 min)

### 1. Create Twilio API Key in console

[console.twilio.com](https://console.twilio.com) → top-right account dropdown → **API keys & tokens** → **Create API key**

- Friendly name: `terraform`
- Region: same as your account default (US1 unless you set otherwise)
- Key type: **Standard** (sufficient for Voice + SIP IaC)

**Copy the SID + Secret immediately** — the Secret is shown ONCE, never re-shown. If you miss it, delete + recreate the key.

### 2. Store in 1Password

Create a new 1P item:
- Title: `Twilio API (tf)`
- Category: API Credential
- Fields:
  - `account_sid` = your Account SID (starts with `AC...`, find on console homepage)
  - `api_key_sid` = the SK... from step 1
  - `api_key_secret` = the secret from step 1 (Concealed)

### 3. Add GitHub repo secrets

For the future `terraform-twilio.yml` workflow:
- `TWILIO_ACCOUNT_SID`
- `TWILIO_API_KEY_SID`
- `TWILIO_API_KEY_SECRET`

## Initial import

After credentials are in place:

```bash
cd infra/terraform/twilio
terraform init

# Set env vars from 1P
export TWILIO_ACCOUNT_SID=$(op item get "Twilio API (tf)" --fields account_sid --reveal)
export TWILIO_API_KEY_SID=$(op item get "Twilio API (tf)" --fields api_key_sid --reveal)
export TWILIO_API_KEY_SECRET=$(op item get "Twilio API (tf)" --fields api_key_secret --reveal)

# Discover current state — what's actually in the account today
# (these listings will be the source of SIDs to import)
twilio api:core:incoming-phone-numbers:list      # find DIDs + their PN-SIDs
twilio api:core:addresses:list                   # any existing emergency addrs
twilio api:trunking:trunks:list                  # SIP trunks + their TK-SIDs
```

(If you don't have the `twilio` CLI, install via `brew install twilio-cli`. Or use `curl https://api.twilio.com/2010-04-01/Accounts/$TWILIO_ACCOUNT_SID/IncomingPhoneNumbers.json -u "$TWILIO_API_KEY_SID:$TWILIO_API_KEY_SECRET"`.)

Then import each resource. The exact SIDs come from the discovery step above:

```bash
# Primary DID (substitute the PN... SID)
terraform import twilio_api_accounts_incoming_phone_numbers_v2010.primary <PN-sid>

# Orphan DID (if keeping)
terraform import 'twilio_api_accounts_incoming_phone_numbers_v2010.orphan[0]' <PN-sid>

# Existing emergency address if any
terraform import twilio_api_accounts_addresses_v2010.primary <AD-sid>

# SIP trunk
terraform import twilio_trunking_trunks_v1.talk <TK-sid>

# Origination URLs for the trunk (one per URL)
terraform import twilio_trunking_origination_urls_v1.talk_primary <TK-sid>/<OU-sid>
```

Run `terraform plan` after import — should show only the deltas representing your INTENDED changes (e.g., new emergency address, secure=true if trunk was UDP).

## Apply the 3 pending fixes

### Task #20 — emergency address

Edit `variables.tf` (or use `terraform.tfvars`):

```hcl
emergency_address = {
  friendly_name    = "Etherport HQ — Talk 911"
  customer_name    = "Graham Smith"
  street           = "1234 Real Street"      # ← actual physical address
  city             = "Seattle"               # ← actual city
  region           = "WA"
  postal_code      = "98101"
  iso_country      = "US"
}
```

After apply, the Address record exists in Twilio AND the primary DID's `emergency_address_sid` points at it. Verified by:

```bash
twilio api:core:incoming-phone-numbers:fetch --sid <PN-sid> -o json | jq .emergencyAddressSid
```

### Task #21 — orphan DID

Pick action via `orphan_did_action` variable:

```hcl
# Option 1: release (stop paying ~$1/mo)
orphan_did_action = "release"
# After apply, manually delete the DID from console (TF can't delete, since
# the resource is no longer in the module).

# Option 2: park on a voicemail Studio flow
orphan_did_action = "route_voicemail"
# Update main.tf voice_url placeholder with real Studio flow URL.

# Option 3: forward to primary DID
orphan_did_action = "route_forward"
# Update main.tf voice_url placeholder with a TwiML Bin that <Dial>s the primary.
```

### Task #22 — SIP trunk UDP → TLS + sRTP

Just update `sip_origination_url` in variables.tf:

```hcl
# Before (UDP):
# sip_origination_url = "sip:talk.wind.etherport.net:5060"

# After (TLS):
sip_origination_url = "sips:talk.wind.etherport.net:5061;transport=tls"
```

And ensure `twilio_trunking_trunks_v1.talk.secure = true` (already in main.tf).

> ⚠ Make sure the SIP endpoint (probably FreePBX or similar at `talk.wind.etherport.net`) actually has TLS+sRTP enabled BEFORE you switch the trunk to require it — otherwise inbound calls break. Standard pattern: enable TLS server-side first, test with a soft-phone, then flip the trunk.

## Apply workflow (future)

Once stable, add `.github/workflows/terraform-twilio.yml` mirroring the
`terraform-cloudflare.yml` pattern. Until then, run from your laptop with the
env vars set as above.

## Rotation

To rotate the API Key:
1. Console → API keys & tokens → click your `terraform` key → **Reset Secret**
2. Copy new Secret → update 1P
3. Update GitHub repo secret `TWILIO_API_KEY_SECRET`
4. Account SID + Key SID don't change, just the Secret

## What's intentionally NOT in this module

- **Studio flows** — visual editor in console, JSON blob in API. Not well-suited to TF; better managed in console.
- **TaskRouter** — not in use
- **IP Messaging / Conversations** — not in use
- **Verify services** — not in use
- **SubAccounts** — not in use

If any become relevant, add them here.
