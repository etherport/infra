# UniFi Talk + Twilio runbook

How voice runs at Windtryst: UniFi Talk on the UDM Pro Max with Twilio
Elastic SIP Trunking as the PSTN provider, fronted by an **asterisk-sbc** that
terminates the external Twilio leg. There is no separate PBX — Talk hosts the
extensions, ring groups, DIDs, and call routing; the SBC is a thin SIP/RTP edge
between Twilio (TLS+sRTP) and Talk (plain UDP/RTP on the LAN).

Talk inventory audited via the Talk REST API (`/proxy/talk/api/...`) against
Talk 5.1.2. See `## How this was audited` at the bottom for endpoints. The
external/Twilio leg's source of truth is `infra/ansible/playbooks/asterisk-sbc.yml`
(+ the PVE firewall scoping in `infra/terraform/proxmox/firewall/standalone-vms.tf`).

## Architecture

The external Twilio leg terminates on the **asterisk-sbc** (VM 1004, `10.10.201.40`)
over **TCP 5061 (SIP-TLS) + UDP 10000-20000 (sRTP)** and bridges internally to
UniFi Talk on `10.10.199.1:6767` (plain UDP SIP + RTP on the LAN). The SBC is the
stable, IaC-managed SIP edge so Talk's fragile built-in 3rd-party-SIP listener
never faces the internet directly.

```
PSTN ─► Twilio Elastic SIP Trunk ──TLS+sRTP──► [ asterisk-sbc ] ──UDP+RTP (LAN)──► UniFi Talk
        (windtryst.pstn.twilio.com)             VM 1004                            10.10.199.1
            │                                   10.10.201.40                       (Talk on the UDM)
            ▼   src=Twilio Signal/Media IPs
WAN ─► UDM Pro Max ("Windroute", 28704e203ed4)
            ├─ Port-forward TCP 5061        → 10.10.201.40 (SBC, SIP-TLS)
            └─ Port-forward UDP 10000-20000 → 10.10.201.40 (SBC, RTP media)
                                                            │
                                                            ▼
                                    UniFi Talk service (controller v5.1.2; listens on TCP 3419 + SIP UDP 6767)
                                            │
                                            ├─ extension 0001 — Graham Smith         (UVP-TOUCH, Office, 10.10.212.250)
                                            ├─ extension 0003 — Windtryst (user)     (UVP-TOUCH, Hallway, 10.10.212.100)
                                            ├─ extension 0004 — Work Room            (UVP-TOUCH-W, Workroom, 10.10.212.114)
                                            ├─ extension 0005 — Terraform Admin      (no handset)
                                            ├─ extension 0007 — Smith SB             (no handset)
                                            └─ ring group ext 0006 "Windtryst"       (rings 0001 → 0004 → 0003 simultaneously, then VM to Graham)
```

Inbound flow: PSTN → Twilio → UDM WAN (SIP-TLS on TCP 5061 from Twilio signalling
CIDRs, port-forwarded to the SBC at `10.10.201.40`) → asterisk-sbc → forwards the
call to Talk on `10.10.199.1:6767` (plain UDP) → ring group / extension handset
over the Talk VLAN (`10.10.212.0/24`).

Outbound: handset → Talk service on the UDM → asterisk-sbc → SIP INVITE to
`windtryst.pstn.twilio.com` (TLS) → Twilio edge → PSTN. Twilio authenticates the
SBC via a credential list (`graham` + password); the SBC trusts inbound Twilio via
its PJSIP `identify` ACL (the 8 Twilio signalling /30s). The Talk-side trunk no
longer faces the WAN — it only speaks to the SBC on the LAN.

The SBC's `external_signaling_address` is pinned to the WAN IP **literal**
`47.159.189.5` (not the `sip.wind.etherport.net` hostname): the VM's split-horizon
DNS can't resolve that name, so a hostname there silently falls back to the private
bind IP and breaks Twilio's ACK (408 ACK Timeout). The same WAN IP literal is also
hardcoded in the cloudflare + twilio TF modules — **if the residential WAN IP ever
changes, update all three.** A `sbc-update-extip` systemd timer self-heals the
external address across WAN failover/IP drift.

## Inventory

**External leg — Twilio ⇄ asterisk-sbc** (`infra/ansible/playbooks/asterisk-sbc.yml`):

| Field | Value |
|---|---|
| Twilio trunk | Windtryst (`TK18c876a18dc3b0f64449d0c745d9aec6`), `domain_name` `windtryst.pstn.twilio.com` |
| Twilio termination target (outbound) | `windtryst.pstn.twilio.com` (generic — Twilio picks the nearest healthy edge) |
| Transport (external) | **TLS on TCP 5061** (signalling) + **sRTP** on UDP 10000-20000 (media) |
| SBC TLS cert | Let's Encrypt for `sip.wind.etherport.net` (certbot DNS-01 via Cloudflare) |
| Twilio auth (outbound) | credential list `graham` + SOPS password (`asterisk-sbc.sops.yaml`) |
| Inbound trust (toll-fraud guard) | PJSIP `identify` ACL = the 8 Twilio signalling /30s (below) |
| Audio codecs | `PCMU, PCMA` (G.711 µ-law / A-law) |
| Twilio signalling CIDRs | `54.172.60.0/30`, `54.244.51.0/30`, `54.171.127.192/30`, `35.156.191.128/30`, `54.65.63.192/30`, `54.169.127.128/30`, `54.252.254.64/30`, `177.71.206.192/30` |
| Twilio media (sRTP) range | `168.86.128.0/18` |
| DIDs on trunk | `+1 (909) 414-2433` (active route), `+1 (909) 414-1003` (orphan — see TODOs) |

**Internal leg — asterisk-sbc ⇄ UniFi Talk** (LAN):

| Field | Value |
|---|---|
| Talk trunk name | `Twilio` (id=1, enabled) — now points at the SBC, not the WAN |
| Talk listen target | `10.10.199.1:6767` (Talk's 3rd-party-SIP listener on the UDM Default VLAN) |
| Transport (internal) | **plain UDP** SIP `6767` + RTP — LAN-only, never internet-facing |
| SIP REGISTER | disabled — the SBC↔Talk leg is IP/static |
| Audio codecs | `PCMU, PCMA` |
| Routing scope | `route_all_countries: true` |

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
| Twilio console login / API keys | 1Password item **"Twilio"** (Private vault, id `bv3dqsbwdqjl7nqj6aqqd6343i`). Also `twilio-tf-api` for the API key (see Twilio API auth, below). |
| Twilio SIP credential-list password (SBC ⇄ Twilio auth) | **SOPS-encrypted** in `infra/ansible/playbooks/secrets/asterisk-sbc.sops.yaml` (`twilio_sip_password`) — the SBC's credential-list secret. Same value Talk's hidden trunk `password` used. |
| Cloudflare DNS-01 token (SBC TLS cert) | SOPS in the same `asterisk-sbc.sops.yaml` (`cloudflare_dns_token`, Zone:DNS:Edit). |
| Per-extension SIP passwords (handset auth to Talk) | Stored inside Talk per-user (`users[*].sip_password`). Managed by Talk; not a user-facing credential. |
| Stale legacy item | 1Password **"Twilio Credentials (windtryst)"** (Private, id `43lsajaf6bgzvnuqm26v32uxem`, 2019). Predates Talk; **TODO: confirm + archive**. |
| Misc supporting items | "Twilio SIP ACL (Campaign)", "Sendgrid - Twilio", two `www.twilio.com` login items. All appear unrelated to the current trunk. |

Note: the **SBC's** secrets are in SOPS (`asterisk-sbc.sops.yaml`), decrypted
headlessly in CI/locally via the age key — so the external-leg auth is fully IaC.
**Talk's own** config (extensions, ring groups, DIDs) is **not** in the repo: the
`ubiquiti-community/unifi` provider (the retired `paultyng` fork's successor, M125) doesn't model Talk, so that state lives only on the UDM.

## Port-forwards on the UDM

The WAN port-forwards now target the **asterisk-sbc** (`10.10.201.40`), not the
UDM itself:

| Name | Proto | Dst port | Forward target | Source restriction (firewall group) |
|---|---|---|---|---|
| `Twilio-SIP` | **TCP** | `5061` | `10.10.201.40:5061` (SBC, SIP-TLS) | **"Twilio Signal IPs"** — 8 × /30 regional signalling CIDRs |
| `Twilio-Media-Signal` | UDP | `10000-20000` | `10.10.201.40:10000-20000` (SBC, RTP) | **"Twilio Media IPs"** — `168.86.128.0/18` |

The matching PVE host firewall on VM 1004 is source-scoped (M77 Stage-2b,
`standalone-vms.tf`): `5061/TCP` ← the `twilio-signaling` ipset (8 /30s), RTP
`10000-20000/UDP` ← `168.86.128.0/18` (Twilio media) + the internal Talk/LAN
sources, and plain `5060/UDP` ← internal Talk/LAN only. Those firewall scopes are a
superset-or-equal of the SBC's PJSIP `identify` ACL, so they can never drop a call
the SBC would have answered.

> ⚠️ **Two legacy UDM user firewall rules remain vestigial:** `Allow-Twilio-SIP-6767`
> and `Allow-Twilio-Media-10000-60000` (source = Twilio Signal/Media groups, dest =
> the Gateway zone) — the old direct Twilio→UDM-Talk path. External Twilio no longer
> hits `:6767` on the UDM; these are cleanup candidates.

ACL note: the 8 Twilio signalling /30s + the global media `/18` match Twilio's
published ranges (https://www.twilio.com/docs/sip-trunking/ip-addresses) —
Virginia, Oregon, Ireland, Frankfurt, Tokyo, Singapore, Sydney, São Paulo
signalling + the media /18. Re-check quarterly (Twilio may add ranges).

## Disaster recovery

> Talk config is **not** in IaC. The `ubiquiti-community/unifi` Terraform provider
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
3. **Re-point Talk's 3rd-party-SIP trunk at the SBC.** On a fresh Talk
   install the trunk `proxy` must point at the SBC (`10.10.201.40`),
   transport `udp`, port matching the SBC's Talk leg — not at a Twilio
   edge directly. (The SBC, not Talk, holds the WAN-facing TLS leg.)
4. **Re-provision the SBC if VM 1004 was lost** — re-run
   `ansible-playbook -i inventory/wind playbooks/asterisk-sbc.yml`
   (idempotent; re-issues the LE cert via DNS-01 and re-templates PJSIP).
5. **Verify trunk reach** before declaring done:
   - Outbound: place a test call from ext 0001 to a mobile.
   - Inbound: call `+1-909-414-2433`; all three UVPs should ring.
   - If inbound fails, check the SBC: `asterisk -rx "pjsip show endpoints"`
     and the PVE/UDM firewall scopes (`:5061` from the Twilio signalling
     IPset, RTP from the Twilio media `/18`).
6. **Twilio side** — no action needed unless the trunk's Origination URL
   (`sips:sip.wind.etherport.net:5061;transport=tls`) or the WAN IP changed.
   Twilio authenticates the SBC via the credential list, not a registration.

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

1. **The internal SBC↔Talk leg is plain UDP/RTP** (LAN-only). The WAN-facing
   Twilio↔SBC leg is TLS+sRTP, so external call metadata + media are encrypted;
   the cleartext segment is confined to the LAN between the SBC (`.40`) and Talk
   (`10.10.199.1`). This is by design — UniFi Talk doesn't support sRTP, which is
   the whole reason the SBC exists. Closing it fully would require Ubiquiti
   shipping sRTP in Talk (then the SBC could be retired or the Talk leg secured).
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
   the only safety net. If the `ubiquiti-community/unifi` provider ever models
   Talk (or Ubiquiti ships an official one), move trunk + extensions
   here. Until then, snapshot `/proxy/talk/api/third_party_sip/gateway_list`
   and `/proxy/talk/api/users` into source control on changes.
8. **Twilio IP ranges drift.** Twilio explicitly warns "not all of these
   IPs host active gateways at a given time" and may add ranges. **TODO:
   re-check the Twilio signalling /30s + media /18 quarterly** — they're
   pinned in three places (`asterisk-sbc.yml` `twilio_signaling_nets`, the
   `twilio-signaling` ipset in `standalone-vms.tf`, and the UDM "Twilio Signal/Media
   IPs" groups) — and diff against https://www.twilio.com/docs/sip-trunking/ip-addresses.

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

## Twilio side — account, API auth

Covers the Twilio half of the trunk: account/DID/emergency-address state and API
auth + gotchas. The UniFi Talk + SBC half is documented above. (This section is
the canonical home for the Twilio detail formerly in `twilio-talk.md`, which now
redirects here.)

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
- `secure`: false (UniFi Talk doesn't support sRTP; the SBC handles the secure
  Twilio leg and bridges to Talk in cleartext on the LAN — see the architecture above)
- `cnam_lookup`: true
- Origination URL: `sips:sip.wind.etherport.net:5061;transport=tls` (TLS signalling
  to the SBC; `sip.wind.etherport.net` → the UDM WAN, port-forwarded to the SBC `.40`)

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

## Migration history

How this got here — the original direct Twilio→UDM-Talk path, the UDP→TLS+sRTP push
(task #22 / #80), and the Twilio-account cleanups (orphan-DID release, duplicate
emergency-address delete, the 2026-05-27 origination-URL move) — is archived in
[`archive/unifi-talk-twilio-migration-history.md`](archive/unifi-talk-twilio-migration-history.md).
