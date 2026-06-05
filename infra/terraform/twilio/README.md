# Twilio Talk — Terraform module

Brings the Twilio Programmable Voice + SIP trunk setup under IaC, and
turns the 3 pending Talk tasks into TF apply'd changes:

| Task | Resolution path | Status |
|---|---|---|
| #20 fix 911 emergency address | New `twilio_api_accounts_addresses` resource + bound to primary DID via `emergency_address_sid` | ✅ applied |
| #21 route or release orphan DID | `orphan_did_action` variable: `release`, `route_voicemail`, or `route_forward` | ✅ released |
| #22 migrate SIP trunk UDP→TLS+sRTP | `sips:` scheme in origination URL (TLS signaling) — done. `twilio_trunking_trunks_v1.secure = true` (full TLS+sRTP) | 🟡 **partial** — TLS signaling live (`sips:sip.wind.etherport.net:5061;transport=tls`). Full `secure=true` deferred: UniFi Talk has no sRTP, which Twilio Secure Trunking requires. Revisit when Ubiquiti ships sRTP or an SBC is inserted (task #80). |
| #23 uniform inbound SMS routing | `messaging-service.tf`: one Messaging Service (inbound webhook = the shared Lambda `var.webhook_url`, `use_inbound_webhook_on_number=false`) with all DIDs added as senders. Needed because a direct `sms_url` change on the primary DID is blocked by Twilio's E911 lock (ApiError 21631) — joining a Messaging Service routes SMS without touching the number's emergency-locked config. | ✅ applied |

## Prerequisites (one-time, ~5 min)

### 1. Create Twilio API Key in console

[console.twilio.com](https://console.twilio.com) → top-right account dropdown → **API keys & tokens** → **Create API key**

- Friendly name: `terraform`
- Region: same as your account default (US1 unless you set otherwise)
- Key type: **Standard** (sufficient for Voice + SIP IaC)

**Copy the SID + Secret immediately** — the Secret is shown ONCE, never re-shown. If you miss it, delete + recreate the key.

### 2. Store in 1Password

1P item: `twilio-tf-token` (ID `xb2652itobj4k3ytnz53b3hm7y`).

Field mapping (note the spaces — exact field names as stored):
- `username` = the **API Key SID** (starts with `SK...`)
- `credential` = the **API Key Secret** (Concealed)
- `account name` = the **Account SID** (starts with `AC...`)

The Account SID is distinct from the API Key SID. Find it on the
[console homepage](https://console.twilio.com) top-right, or pull from
any console URL (`.../console/account/{AC...}/...`).

### 3. Add GitHub repo secrets

For the `terraform-twilio.yml` workflow (exact secret names it reads):
- `TWILIO_ACCOUNT_SID` (AC…)
- `TWILIO_API_KEY` (SK… — the API Key SID)
- `TWILIO_API_SECRET` (the API Key secret)

## Initial import

After credentials are in place:

```bash
cd infra/terraform/twilio
terraform init

# Set env vars from 1P (item "twilio-tf-api")
export TWILIO_ACCOUNT_SID=$(op item get twilio-tf-api --fields 'account name' --reveal)
export TWILIO_API_KEY=$(op item get twilio-tf-api --fields username --reveal)
export TWILIO_API_SECRET=$(op item get twilio-tf-api --fields credential --reveal)

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
terraform import twilio_api_accounts_incoming_phone_numbers.primary <PN-sid>

# Orphan DID (if keeping)
terraform import 'twilio_api_accounts_incoming_phone_numbers.orphan[0]' <PN-sid>

# Existing emergency address if any
terraform import twilio_api_accounts_addresses.primary <AD-sid>

# SIP trunk
terraform import twilio_trunking_trunks_v1.talk <TK-sid>

# Origination URLs for the trunk (one per URL)
terraform import twilio_trunking_trunks_origination_urls_v1.talk_primary <TK-sid>/<OU-sid>
```

> The trunk's number assignment + credential-list link are **not** TF-managed
> (the provider can't import them without a perpetual replace diff). They're
> configured directly in Twilio — see the note in `main.tf`.

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

### Task #22 — SIP trunk TLS

**Done (TLS signaling):** `sip_origination_url = "sips:sip.wind.etherport.net:5061;transport=tls"`.
The host is a CF DNS A record → the UDM WAN IP; the UDM Talk side runs the
3rd-party SIP config on 5061 with `register-transport: tls`.

**Deferred (full secure trunking):** `sip_trunk_secure` stays `false`.
Twilio Secure Trunking requires TLS **and** sRTP; UniFi Talk doesn't do
sRTP, so flipping `secure=true` would break calls. Revisit when Ubiquiti
ships sRTP, or front the UDM with an SBC (FreeSWITCH/Kamailio/Asterisk) —
task #80. See `docs/runbooks/twilio-talk.md`.

> ⚠ Before ever setting `secure=true`, confirm the SIP endpoint actually
> negotiates TLS+sRTP — otherwise inbound calls break. Enable server-side
> first, test with a soft-phone, then flip the trunk.

## Apply workflow (future)

Once stable, add `.github/workflows/terraform-twilio.yml` mirroring the
`terraform-cloudflare.yml` pattern. Until then, run from your laptop with the
env vars set as above.

## Rotation

To rotate the API Key:
1. Console → API keys & tokens → click your `terraform` key → **Reset Secret**
2. Copy new Secret → `op item edit twilio-tf-token credential=<new>`
3. Update GitHub repo secret `TWILIO_API_KEY_SECRET`
4. Account SID + Key SID don't change, just the Secret

## What's intentionally NOT in this module

- **Studio flows** — visual editor in console, JSON blob in API. Not well-suited to TF; better managed in console.
- **TaskRouter** — not in use
- **IP Messaging / Conversations** — not in use
- **Verify services** — not in use
- **SubAccounts** — not in use

If any become relevant, add them here.
