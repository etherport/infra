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
- `secure`: false (sRTP unsupported by UniFi Talk — blocks full secure trunking; see task #80)
- `cnam_lookup`: true
- Origination URL: `sips:sip.wind.etherport.net:5061;transport=tls` (TLS signaling, RTP media — migrated 2026-05-27 from broken `sip:wind.gmsmeg.net:6767`)

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

**Step 1 — restore inbound routing + TLS signaling (DONE 2026-05-27):**

- CF DNS A record `sip.wind.etherport.net` → `47.159.189.5` (UDM WAN)
  added to `cloudflare/variables.tf` dns_records_a.
- Windtryst trunk Origination URL flipped from `sip:wind.gmsmeg.net:6767`
  → `sips:sip.wind.etherport.net:5061;transport=tls`.
- UDM-side: user flipped proxy to port 5061 + added Custom Field
  `register-transport: tls` in the UniFi Talk 3rd-party SIP config
  (UI change; no IaC for Talk yet — see "IaC for UniFi Talk config"
  below).
- secure=false on the Twilio trunk stays — sRTP support missing on
  UniFi Talk would break calls under secure=true.

**Step 2 — full TLS+sRTP (blocked, deferred to task #80):**

- UniFi Talk does not support sRTP (multi-year open feature request).
- Workaround: SBC (FreeSWITCH/Kamailio/Asterisk PJSIP) between Twilio
  (TLS+sRTP) and UDM (plain RTP over LAN). Effort: half day to a day.
- Or: wait for Ubiquiti to ship sRTP, then flip Twilio `secure=true`
  and call it done.

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
- 2026-05-27: SIP origination URL migrated to
  `sips:sip.wind.etherport.net:5061;transport=tls` (TLS signaling,
  cleartext RTP). Restores inbound routing AND encrypts signaling.
  Full TLS+sRTP blocked by UniFi Talk → task #80 (SBC).
- Earlier: confirmed `gmsmeg.net` is delegated to AWS NS but has no
  hosted zone — origination URL had been silently broken for inbound
  for an unknown period. Likely few/no inbound calls noticed.
