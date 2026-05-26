# Twilio Talk + UniFi 3rd-party SIP — current state runbook

Captures the end-to-end architecture, the state we landed in on 2026-05-26,
and the remaining work on #22 (UDP → TLS+sRTP migration). Future sessions
should read this before touching Twilio/UDM SIP config.

## Architecture

```
PSTN  ─┐
       │ inbound
       ▼
   ┌──────────────────────────┐                ┌──────────────────────────┐
   │ Twilio Programmable      │                │ UDM Pro                  │
   │ Voice (umatilla edge)    │  ◀── outbound  │  UniFi Talk app          │
   │                          │       SIP/UDP  │  3rd-party SIP provider  │
   │ Trunk: Windtryst         │                │  (Custom)                │
   │  - secure: false (UDP)   │                │                          │
   │  - origination URL: TBD  │ ──▶ inbound    │  Outbound proxy:         │
   │                          │     SIP/UDP    │  windtryst.pstn.umatilla │
   │  DIDs:                   │ ──────────────▶│  .twilio.com:5060        │
   │   +19094142433 (primary) │                │                          │
   └──────────────────────────┘                │  transport: udp          │
                                                │  register: false         │
                                                │  username: graham        │
                                                │  from-user: windtryst    │
                                                │  Phone #: +19094142433   │
                                                └──────────────────────────┘
```

## Twilio account state (as of 2026-05-26)

Account: `AC68e0bdb45aeae2e11e31b6f67fd9bb65` (grahamsm@gmail.com).

**DIDs (4):**

| Number | SID | Trunk | Emergency | Status |
|---|---|---|---|---|
| `+19094142433` | `PN2b496425001cb3534ee7ed38a4c3e2f3` | Windtryst | AD1fe17 / Active / **registered** | Primary Talk DID |
| `+19094308285` | `PN79ff4214416d86d5a3623903298f239f` | — | — | "Campaign mobile" Studio Flow |
| `+447545911500` | `PN3c9e7e833c6f4e03ffe47551c4f4e024` | — | — | Graham UK Mobile |
| `+14246257334` | `PNdcdf097e579cb206a814588b8e34e286` | — | — | Graham US personal |

`emergency_address_status: registered` on `+19094142433` is the
**E911 service registration** that took a Twilio support ticket to set up
years ago. PRESERVE THIS. Do not touch the DID's `emergency_address_sid`
or call DELETE on it without first contacting Twilio support.

**SIP Trunk Windtryst (`TK18c876a18dc3b0f64449d0c745d9aec6`):**

- `domain_name`: `windtryst.pstn.twilio.com`
- `secure`: false (UDP)
- `cnam_lookup`: true
- Origination URL: `sip:wind.gmsmeg.net:6767` ← **broken** (gmsmeg.net DNS deprecated; zone delegated to AWS NS that have no zone)

**Emergency address `AD1fe17`:**

- Friendly name: "Cabin"
- 843 GREENBRIAR DR, SKYFOREST, CA 92385 US
- `emergency_enabled: true`, `validated: true`, `verified: false`
- `verified: false` is **normal** — that's a separate concept from
  the DID-level E911 service registration. What matters is the DID's
  `emergency_address_status: registered` (above).

## UniFi Talk side

UDM Pro running UniFi OS, Talk app in 3rd-party SIP mode. Configuration
captured from web UI screenshot (UDM → Settings → Talk → 3rd party SIP):

| Field | Value |
|---|---|
| Provider | Custom (named "Twilio") |
| proxy | `windtryst.pstn.umatilla.twilio.com:5060` |
| password | (set in UI, also in 1P) |
| register | false |
| username | graham |
| from-user | windtryst |
| transport | **udp** |
| Destination Countries | (blank) |
| Handle All Outgoing Calls By Default | true |
| Phone Numbers | `+1 909 414 2433` |

**IP Address Range allowlist (Twilio umatilla edge):**

```
54.172.60.0/30
54.244.51.0/30
54.171.127.192/30
35.156.191.128/30
54.65.63.192/30
54.169.127.128/30
```

These restrict inbound SIP to known Twilio IPs.

## Auth (Twilio API)

API Key in 1P item `twilio-tf-api`:

- `username` = SK… (API Key SID)
- `credential` = secret
- `account name` = AC… (Account SID — note: field name has a space)

```bash
export TWILIO_ACCOUNT_SID=$(op item get twilio-tf-api --fields 'account name' --reveal)
export TWILIO_API_KEY=$(op item get twilio-tf-api --fields username --reveal)
export TWILIO_API_SECRET=$(op item get twilio-tf-api --fields credential --reveal)
```

### Gotchas

1. **Direct `curl -u SK:secret` returns 401 against api.twilio.com**
   even with valid credentials. Reproducible with both curl and stdlib
   urllib. Root cause unknown — possibly a User-Agent or TLS quirk.
   Use Twilio CLI or Twilio Python SDK instead.

2. **Twilio CLI silently drops empty-string field clears.** Calling
   `incoming-phone-numbers:update --emergency-address-sid ''` returns
   200 OK with the response showing the field as empty, but the value
   in Twilio's actual state is unchanged. Use Twilio Python SDK
   (`pip install twilio` + `client.incoming_phone_numbers(...).update(emergency_address_sid='')`)
   for these mutations.

3. **`emergency_address_status: registered` blocks DELETE.** A DID
   with active E911 registration returns error 21631 on DELETE. Path
   to release: detach trunk via `api:trunking:v1:trunks:phone-numbers:remove`,
   set emergency_status to Inactive (best-effort via SDK), then DELETE.

## Outstanding tasks

### #22 SIP trunk UDP → TLS+sRTP

**Step 1 — restore inbound routing (low-risk, blocked on DNS migration):**

- Add explicit A record `sip.wind.etherport.net` → `47.159.189.5`
  (UDM WAN). Overrides the `*.wind.etherport.net` wildcard which
  currently points at the AWS ALB and silently breaks SIP.
- Update Windtryst trunk Origination URL: `sip:wind.gmsmeg.net:6767`
  → `sip:sip.wind.etherport.net:5060`.
- No UDM-side changes; transport stays UDP.

**Blocker:** etherport.net DNS migration to Cloudflare in progress.
Do the DNS migration first, then add the SIP record on the CF side.

**Step 2 — TLS+sRTP migration (deferred):**

- UniFi Talk supports `transport: tls` in the 3rd-party SIP config
  (dropdown in UI).
- Need:
  - TLS cert for `sip.wind.etherport.net` (Let's Encrypt via UDM,
    or ACM + manual cert push).
  - UDM port forward for TLS port (5061 typical) to wherever Talk
    listens internally.
  - Twilio trunk: `secure=true`, scheme `sips:` in origination URL.
- Reasonable order: enable TLS server-side, verify with a soft-phone
  test from outside, then flip Twilio trunk (single atomic change).
  Pre-test mitigates the failure mode where Twilio requires TLS
  but the UDM hasn't yet got a working listener.

### IaC for UniFi Talk config

Currently the UDM Talk 3rd-party SIP config is UI-managed. The user's
preference is durable IaC. Research outcome in
[learning-roadmap.md](auto-remediation/learning-roadmap.md) follow-ups
or a future runbook once we know the path.

Pattern likely mirrors existing UniFi firewall IaC: Ansible playbook
hitting the UniFi controller's REST API directly (since paultyng
TF provider is broken on UniFi 10+ per session memory).

## History on this thread

- 2026-05-26: Released `+19094141003` (orphan secondary Talk DID).
  Detached from trunk via trunking endpoint; SDK DELETE succeeded.
- 2026-05-26: Deleted duplicate Cabin emergency address `ADa91ea9`.
  Original `AD1fe17` retained — it's the one attached to the keeper DID.
- Earlier: confirmed `gmsmeg.net` is delegated to AWS NS but has no
  hosted zone — origination URL has been silently broken for inbound
  for an unknown period. Likely few/no inbound calls noticed.
