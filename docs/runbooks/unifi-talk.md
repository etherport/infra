# UniFi Talk + Twilio runbook

How voice runs at Windtryst: UniFi Talk on the UDM Pro Max with Twilio
Elastic SIP Trunking as the PSTN provider. No separate PBX — Talk hosts
all SIP signalling and call routing directly on the gateway.

Audited via the Talk REST API (`/proxy/talk/api/...`) on 2026-05-17 against
Talk 5.1.2. See `## How this was audited` at the bottom for endpoints.

> ⚠️ **STALE — external Twilio path changed (verified live 2026-06-29).** This runbook
> describes the **original direct** path (Twilio → UDM Talk, UDP `6767`/`10000-60000` →
> `10.10.199.1`). That was **superseded** by an **asterisk-sbc SIP bridge**: the live UDM
> port-forwards are now **`Twilio-SIP` TCP `5061` → `10.10.201.40`** and **`Twilio-Media-Signal`
> UDP `10000-20000` → `10.10.201.40`** (the asterisk SBC, VM 1004), which then bridges to UniFi
> Talk internally on `10.10.199.1:6767`. Source of truth for the external/Twilio leg is now
> **`infra/ansible/playbooks/asterisk-sbc.yml`** (+ the PVE firewall scoping in
> `infra/terraform/proxmox/firewall/standalone-vms.tf`). The Talk extension/ring-group/internal
> detail below is still accurate; the **Twilio-facing port-forward + signalling specifics are not**.
> Full refresh tracked under M17. The legacy `Allow-Twilio-SIP-6767` / `…-10000-60000` UDM rules
> are now vestigial (cleanup candidates).

## Architecture

```
PSTN  ──► Twilio Elastic SIP Trunk (FQDN: windtryst.pstn.umatilla.twilio.com:5060/UDP)
            │
            ▼   src=Twilio Signal/Media IPs (firewall groups)
WAN  ──►  UDM Pro Max ("Windroute", 28704e203ed4)
            │     ├─ Port-forward UDP 6767       → 10.10.199.1 (UDM Default VLAN IP)
            │     └─ Port-forward UDP 10000-60000 → 10.10.199.1 (RTP media)
            ▼
        UniFi Talk service (controller v5.1.2, listens on TCP 3419 + SIP UDP 6767)
            │
            ├─ extension 0001 — Graham Smith         (UVP-TOUCH, Office, 10.10.212.250)
            ├─ extension 0003 — Windtryst (user)     (UVP-TOUCH, Hallway, 10.10.212.100)
            ├─ extension 0004 — Work Room            (UVP-TOUCH-W, Workroom, 10.10.212.114)
            ├─ extension 0005 — Terraform Admin      (no handset)
            ├─ extension 0007 — Smith SB             (no handset)
            └─ ring group ext 0006 "Windtryst"       (rings 0001 → 0004 → 0003 simultaneously, then VM to Graham)
```

Inbound flow: PSTN → Twilio → UDM WAN (signalling 5060/UDP from Twilio
signal CIDRs, ports forwarded to UDP 6767 by NAT) → Talk service →
ring group / extension handset over the Talk VLAN (`10.10.212.0/24`).

Outbound: handset → Talk service on UDM → SIP INVITE to
`windtryst.pstn.umatilla.twilio.com:5060/UDP` → Twilio Oregon edge → PSTN.
Twilio authenticates outbound via the source-IP ACL configured on the
trunk (no SIP REGISTER — `register: "false"`).

## Inventory

### SIP trunk (Talk side)

| Field | Value |
|---|---|
| Trunk name | `Twilio` (id=1, enabled) |
| Twilio termination FQDN | `windtryst.pstn.umatilla.twilio.com:5060` |
| Twilio edge region | Umatilla (`us-west`, Oregon) |
| Transport | **UDP** — *not* TLS / not 5061 |
| SIP REGISTER | disabled — IP-auth in both directions |
| SIP listen port (UDM) | UDP 6767 (`nat_needs_static_port=true`, `static_port=6767`) |
| Audio codecs | `PCMU, PCMA` (G.711 µ-law / A-law) |
| Inbound ACL (CIDRs) | `54.172.60.0/30`, `54.244.51.0/30`, `54.171.127.192/30`, `35.156.191.128/30`, `54.65.63.192/30`, `54.169.127.128/30`, `54.252.254.64/30`, `177.71.206.192/30`, `168.86.128.0/18` |
| Routing scope | `route_all_countries: true` |
| DIDs on trunk | `+1 (909) 414-1003`, `+1 (909) 414-2433` |

### DIDs

| DID | Group/Route | Notes |
|---|---|---|
| `+1 (909) 414-1003` | *(none)* — orphan number with no inbound route | **TODO: confirm in UI** — is this a spare/forwarded number, or should it be released? |
| `+1 (909) 414-2433` | Ring group "Windtryst" (ext 0006) | Simultaneous ring to ext 0001 → 0004 → 0003, 30s leg timeout, no-answer → voicemail (mailbox: Graham) |

### Extensions

| Ext | User UUID | Display name | Email | Handset | Handset MAC / IP |
|---|---|---|---|---|---|
| 0001 | `86845a20-…ef97e` | Graham Smith | grahamsm@gmail.com | UVP-TOUCH "Office (Graham)" | `68:d7:9a:7f:9f:df` / 10.10.212.250 |
| 0003 | `2108bbad-…aaf1` | Windtryst       | windtryst@grahamsmith.net | UVP-TOUCH "Hallway" | `68:d7:9a:7f:da:7d` / 10.10.212.100 |
| 0004 | `04401b4d-…6687` | Work Room       | workroom@grahamsmith.net | UVP-TOUCH-W "Workroom" | `60:22:32:0c:65:a7` / 10.10.212.114 |
| 0005 | `169390f4-…68a8` | Terraform Admin | g@grahamsmith.net | — | — |
| 0006 | *(ring group)*   | Windtryst (group) | — | — | — |
| 0007 | `990d042c-…bf16` | Smith SB        | info@smithforsb.com | — | — |

All three physical UVP phones are `sip_reg: true` (registered to local Talk),
firmware `v1.21.17`, with `v1.24.8` available.

> **Identity ownership note (2026-05-27):** the `*@grahamsmith.net` and
> `info@smithforsb.com` addresses above receive voicemail-to-email via
> the SES forwarder. The `grahamsmith.net` + `smithforsb.com` SES
> identities + receipt rules moved to the `personal-web` repo on
> 2026-05-27 (terraform/ses-email-forward) — the forwarder Lambda
> itself still lives in homelab (`infra/terraform/aws/email-forward`).
> Mail delivery is unchanged; just noting the IaC split so future
> debugging looks in the right repo.

### Other Talk objects

- **Parking lots**: 1 — "Windtryst", 300s park timeout, on-timeout → voicemail (Graham).
- **Ring flows / Smart Attendants / IVRs**: none configured.
- **Switchboard**: empty.
- **Call recording**: enabled globally (`call_log_recording_enabled: true`).
- **Voicemail-to-email**: enabled. Transcriptions enabled. Slack/Teams: disabled.
- **AI call transcriptions**: enabled.
- **Global VM greeting**: `global_greeting.mp3`. Hold music: `Jazz.wav`.
- **Logging level**: `debug` (verbose — consider `info`). **SIP trace**: off.

## Credentials sources

| Secret | Where |
|---|---|
| Twilio console login / API keys | 1Password item **"Twilio"** (Private vault, id `bv3dqsbwdqjl7nqj6aqqd6343i`, last updated 2025-05-24). |
| Twilio SIP trunk termination secret (configured on the Talk trunk) | Stored inside Talk: `third_party_sip/gateway_list[0].gateway_params.password`. Visible to any UDM `talk.management:admin`. **Not** mirrored to 1Password as of audit — TODO. |
| Per-extension SIP passwords (handset auth to Talk) | Stored inside Talk per-user (`users[*].sip_password`). Managed by Talk; not a user-facing credential. |
| Stale legacy item | 1Password **"Twilio Credentials (windtryst)"** (Private, id `43lsajaf6bgzvnuqm26v32uxem`, last updated 2019-11-11). Predates Talk; **TODO: confirm + archive**. |
| Misc supporting items | "Twilio SIP ACL (Campaign)" (2023), "Sendgrid - Twilio" (2023), two `www.twilio.com` login items (2020). All appear unrelated to current trunk. |

Note: this runbook intentionally does not store secrets in the repo — Talk
holds the SIP password and the TF provider doesn't model Talk, so there's
nothing to encrypt with SOPS.

## Port-forwards on the UDM

Read-only audit (`/tmp/unifi-state/port-forwards.json`):

| Name | Proto | Dst port | Forward target | Source restriction (firewall group) |
|---|---|---|---|---|
| `Twilio-SIP` | UDP | `6767` | `10.10.199.1:6767` | **"Twilio Signal IPs"** (`6499f5c3…`) — 8 × /30 regional signalling CIDRs |
| `Twilio-Media-Signal` | UDP | `10000-60000` | `10.10.199.1:10000-60000` | **"Twilio Media IPs"** (`6499f50a…`) — `168.86.128.0/18` |

`10.10.199.1` is the UDM Pro Max's own IP on the Default VLAN — Talk runs
on the gateway and listens on UDP/6767 for SIP and UDP/10000-60000 for RTP
on that interface. (Confirmed by `setting/config.static_port=6767`.)

ACL audit against Twilio's current published ranges
(https://www.twilio.com/docs/sip-trunking/ip-addresses, fetched
2026-05-17): **all 9 CIDRs match Twilio's current list exactly** — Virginia,
Oregon, Ireland, Frankfurt, Tokyo, Singapore, Sydney, São Paulo signalling
+ the global media /18. No drift.

## Disaster recovery

> Talk config is **not** in IaC. The `paultyng/unifi` Terraform provider
> only models the Network app — there's no resource for SIP trunks,
> extensions, ring groups, or DIDs. Talk state lives entirely on the UDM
> and in Twilio's console.

### If the UDM is wiped / replaced

1. **Restore the UniFi OS backup** that includes Talk state:
   - UniFi OS → Settings → Updates & Backups → Backup → restore the most
     recent `.unf` from off-box storage. Talk config is bundled with the
     OS backup (not the Network-app backup).
   - **TODO: confirm a Talk backup is captured by whatever S3 / off-box
     job we use** — at audit time there is no automated UDM backup job
     in this repo. Manual download via the UI is the only path today.
2. **Re-adopt the UVP-TOUCH handsets.** They auto-discover via L2 on the
   Talk VLAN (`10.10.212.0/24`) and re-register once Talk is online.
   Expect to re-enter each handset's PIN.
3. **Verify Twilio trunk reach** before declaring done:
   - Outbound: place a test call from ext 0001 to a mobile.
   - Inbound: call `+1-909-414-2433`; all three UVPs should ring.
   - If inbound fails, check `/proxy/talk/api/third_party_sip/gateway_list`
     — Talk sometimes resets the ACL list on a fresh install and you'll
     need to re-add the Twilio CIDRs.
4. **Twilio side** — no action needed unless the trunk's "Termination URI"
   was rotated. The trunk is keyed off the UDM's source IP via Twilio's
   IP-ACL, not a username/password registration.

### If only Talk is corrupted (rare)

UniFi OS → Applications → Talk → Settings → "Reinstall" preserves Network
but reinitialises Talk. You will lose extensions, ring groups, voicemails,
call logs, recordings. Plan accordingly — there is no per-app Talk export.

### If Twilio is down

There's no failover trunk configured. Outbound calls fail; inbound rolls
to Twilio's voicemail (if enabled on the number) or carrier-busy. **TODO:
consider a secondary trunk** (Twilio Frankfurt edge, Bandwidth, or
Telnyx) for HA — the Talk API exposes adding multiple gateways via
`POST third_party_sip/gateway`.

## Known gaps / TODOs

1. **Trunk transport is UDP, not TLS.** SIP signalling is unencrypted on
   the WAN — anyone in the path between Twilio Oregon and the WAN edge
   can read call metadata. Twilio supports SIP-over-TLS on port 5061 and
   sRTP for media. Switching requires changing `transport: udp` → `tls`
   on the trunk and updating the Twilio termination config + port-forward
   (would also drop the 8 signal-IP ACL entries since TLS is mTLS-style
   auth). **Action:** evaluate moving to TLS+sRTP.
2. ✅ **Emergency address (911) — RESOLVED at the carrier (verified 2026-06-24).** The
   stale failure below was on the *old* PN `PN7b83e…2bccf`; the primary DID was
   re-released/re-acquired (2026-05-26) as **`PN2b496425…`**. Twilio API now confirms
   `+19094142433` → **`emergency_status: Active`**, `emergency_address_sid = AD1fe171…`
   = **843 GREENBRIAR DR SKYFOREST CA** which is **`validated: True, emergency_enabled:
   True`**. 911 routes at the carrier (SIP-trunk 911 uses the DID's emergency address,
   not the UniFi Talk UI field — the Talk `emergency_address/list` being `[]` is the app's
   own view, cosmetic vs carrier delivery). The Twilio TF (`infra/terraform/twilio/`) var
   `emergency_address` matches this address, so no drift. **TF-hygiene follow-up:** confirm
   `twilio_api_accounts_addresses.primary` + the DID are in the twilio TF state (imported)
   so a future `apply` reuses, not duplicates, the address. *(Historical: the assign task
   failed 2025-06-08 "retry limit exceeded" on the old PN.)*
3. **DID `+1 (909) 414-1003` is orphaned** — no group, no extension, no
   ring flow points at it. Inbound calls to that number probably hit
   Talk's default "no route" handling (silent drop or busy). Either:
   route it to an extension/group, or release it on the Twilio console.
4. **Stale 1P item** "Twilio Credentials (windtryst)" (2019). Confirm
   it's not still referenced anywhere, then archive.
5. **No automated UDM backups.** Talk DR depends entirely on someone
   having manually downloaded a recent `.unf`. Add an off-box backup job
   (the UDM SSH-able `unifi-os` shell can `tar` the config to S3 nightly).
6. **Logging level is `debug`** — fine for triage but produces a lot of
   I/O. Set back to `info` once the emergency-address issue is fixed.
7. **Talk not in IaC.** Document the manual settings in this runbook is
   the only safety net. If the `paultyng/unifi` provider ever models
   Talk (or Ubiquiti ships an official one), move trunk + extensions
   here. Until then, snapshot `/proxy/talk/api/third_party_sip/gateway_list`
   and `/proxy/talk/api/users` into source control on changes.
8. **Twilio IP ranges drift.** Twilio explicitly warns "not all of these
   IPs host active gateways at a given time" and may add ranges. The
   audit-on `2026-05-17` matches exactly; **TODO: re-check quarterly**
   or wire a script to diff `/proxy/talk/api/third_party_sip/gateway_list[0].acl_ip_cidr_list`
   against https://www.twilio.com/docs/sip-trunking/ip-addresses.

## How this was audited

Authenticated via `scripts/unifi/dump-state.sh` (1P item `Windroute (tf-admin)`),
then probed undocumented Talk REST endpoints under `/proxy/talk/api/...`.
Useful endpoints discovered:

| Endpoint | Returns |
|---|---|
| `GET /proxy/talk/api/info` | Talk version, host model, owner ULP id, `has_custom_gateways`, region |
| `GET /proxy/talk/api/third_party_sip/gateway_list` | **SIP trunk list with full config including ACL + password** |
| `GET /proxy/talk/api/number/list` | DIDs and their routes (group / orphan) |
| `GET /proxy/talk/api/users` | Talk users with `ext` + `sip_password` |
| `GET /proxy/talk/api/devices` | Adopted UVP handsets, MAC/IP/SIP-reg status |
| `GET /proxy/talk/api/group_list` | Ring groups |
| `GET /proxy/talk/api/setting/config` | Global Talk settings (SIP port, codecs, VM, emergency status) |
| `GET /proxy/talk/api/parking_lots` | Call-park lots |
| `GET /proxy/talk/api/applications` | Talk + Network app status |

Auth pattern (re-uses cookies from `dump-state.sh`):

```bash
CSRF=$(cat /tmp/unifi-state/.csrf)
curl -sk -b /tmp/unifi-state/.cookies -H "X-CSRF-Token: ${CSRF}" \
  "https://10.10.200.1/proxy/talk/api/third_party_sip/gateway_list" | jq .
```

The Talk service itself listens on TCP 3419 (`talk_api_url` in the SPA)
but that port is not exposed off-UDM — use the `/proxy/talk/` reverse
proxy on 443 instead.

---

## Twilio side — account, API auth, and migration notes

> Merged from the former `twilio-talk.md` (2026-06-24). Covers the Twilio half of
> the trunk: account/DID/emergency-address state, API auth + gotchas, and the
> UDP→TLS migration history. The UniFi Talk half is documented above.

### Twilio account state

Account: `AC68e0bdb45aeae2e11e31b6f67fd9bb65` (grahamsm@gmail.com).

**DIDs (Twilio account, 4):**

| Number | SID | Trunk | Emergency | Status |
|---|---|---|---|---|
| `+19094142433` | `PN2b496425001cb3534ee7ed38a4c3e2f3` | Windtryst | AD1fe17 / Active / **registered** | Primary Talk DID |
| `+19094308285` | `PN79ff4214416d86d5a3623903298f239f` | — | — | "Campaign mobile" Studio Flow |
| `+447545911500` | `PN3c9e7e833c6f4e03ffe47551c4f4e024` | — | — | Graham UK Mobile |
| `+14246257334` | `PNdcdf097e579cb206a814588b8e34e286` | — | — | Graham US personal |

`emergency_address_status: registered` on `+19094142433` is the **E911 service
registration** that took a Twilio support ticket to set up years ago. **PRESERVE
THIS.** Do not touch the DID's `emergency_address_sid` or call DELETE on it
without first contacting Twilio support.

**SIP Trunk Windtryst (`TK18c876a18dc3b0f64449d0c745d9aec6`):**

- `domain_name`: `windtryst.pstn.twilio.com`
- `secure`: false (sRTP unsupported by UniFi Talk — blocks full secure trunking; see task #80)
- `cnam_lookup`: true
- Origination URL: `sips:sip.wind.etherport.net:5061;transport=tls` (TLS signaling, cleartext RTP media — set 2026-05-27)

**Emergency address `AD1fe17`:**

- Friendly name: "Cabin"
- 843 GREENBRIAR DR, SKYFOREST, CA 92385 US
- `emergency_enabled: true`, `validated: true`, `verified: false`
- `verified: false` is **normal** — that's a separate concept from the DID-level
  E911 service registration. What matters is the DID's
  `emergency_address_status: registered` (above).

### Twilio API auth

API Key in 1P item `twilio-tf-api`:

- `username` = SK… (API Key SID)
- `credential` = secret
- `account name` = AC… (Account SID — note: field name has a space)

```bash
export TWILIO_ACCOUNT_SID=$(op item get twilio-tf-api --fields 'account name' --reveal)
export TWILIO_API_KEY=$(op item get twilio-tf-api --fields username --reveal)
export TWILIO_API_SECRET=$(op item get twilio-tf-api --fields credential --reveal)
```

**Gotchas:**

1. **Direct `curl -u SK:secret` returns 401 against api.twilio.com** even with
   valid credentials. Reproducible with both curl and stdlib urllib. Root cause
   unknown — possibly a User-Agent or TLS quirk. Use Twilio CLI or Twilio Python
   SDK instead.
2. **Twilio CLI silently drops empty-string field clears.** Calling
   `incoming-phone-numbers:update --emergency-address-sid ''` returns 200 OK with
   the field shown empty, but Twilio's actual state is unchanged. Use the Twilio
   Python SDK
   (`client.incoming_phone_numbers(...).update(emergency_address_sid='')`) for
   these mutations.
3. **`emergency_address_status: registered` blocks DELETE.** A DID with active
   E911 registration returns error 21631 on DELETE. Path to release: detach trunk
   via `api:trunking:v1:trunks:phone-numbers:remove`, set emergency_status to
   Inactive (best-effort via SDK), then DELETE.

### Migration: UDP → TLS+sRTP (task #22 / #80)

**Step 1 — restore inbound routing + TLS signaling (DONE 2026-05-27):**

- CF DNS A record `sip.wind.etherport.net` → `47.159.189.5` (UDM WAN) added to
  `cloudflare/variables.tf` dns_records_a.
- Windtryst trunk Origination URL set to
  `sips:sip.wind.etherport.net:5061;transport=tls` (replacing a dead legacy host
  that had silently broken inbound).
- UDM-side: proxy flipped to port 5061 + Custom Field `register-transport: tls`
  in the UniFi Talk 3rd-party SIP config (UI change; no IaC for Talk yet).
- `secure=false` on the Twilio trunk stays — sRTP support missing on UniFi Talk
  would break calls under `secure=true`.

**Step 2 — full TLS+sRTP (blocked, deferred to task #80):**

- UniFi Talk does not support sRTP (multi-year open feature request).
- Workaround: SBC (FreeSWITCH/Kamailio/Asterisk PJSIP) between Twilio (TLS+sRTP)
  and UDM (plain RTP over LAN). Effort: half day to a day.
- Or: wait for Ubiquiti to ship sRTP, then flip Twilio `secure=true`.

**IaC for UniFi Talk config:** currently UI-managed; durable IaC is the goal.
Pattern likely mirrors existing UniFi firewall IaC (Ansible playbook hitting the
controller REST API directly, since the `paultyng` TF provider is broken on
UniFi 10+).

### Twilio-side history

- 2026-05-26: Released `+19094141003` (orphan secondary Talk DID). Detached from
  trunk via trunking endpoint; SDK DELETE succeeded.
- 2026-05-26: Deleted duplicate Cabin emergency address `ADa91ea9`. Original
  `AD1fe17` retained — it's the one attached to the keeper DID.
- 2026-05-27: SIP origination URL migrated to
  `sips:sip.wind.etherport.net:5061;transport=tls` (TLS signaling, cleartext
  RTP). Restores inbound routing AND encrypts signaling. Full TLS+sRTP blocked by
  UniFi Talk → task #80 (SBC).
- Earlier: the previous origination host had been silently broken for inbound for
  an unknown period (delegated to AWS NS but no hosted zone). Likely few/no
  inbound calls noticed.
