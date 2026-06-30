# UniFi Talk / Twilio migration history (archived)

> 📦 **Historical — completed migrations.** This captures *how the voice path got to its current
> shape* (the original direct Twilio→UDM-Talk design, the UDP→TLS+sRTP push, and the Twilio-account
> cleanups). It is **not** the live reference — for current state see
> [`../unifi-talk.md`](../unifi-talk.md). Kept so the rationale and dated decisions behind the live
> asterisk-sbc bridge are grep-able. Trackers: `docs/planning/outstanding-work.md` (M15/M16/M17,
> task #22 / #80).

All of the below is **done** (or superseded). Newest first.

---

## Twilio voice path: direct UDM-Talk → asterisk-sbc bridge (2026, completed)

**Then (the original direct path):** the Twilio Elastic SIP Trunk terminated **directly on the
UDM** (UniFi Talk on the gateway). Talk listened on UDP `6767` (SIP) and UDP `10000-60000` (RTP) on
`10.10.199.1` (the UDM's own Default-VLAN IP), reached via two UDM port-forwards from the WAN:

```
PSTN  ──► Twilio Elastic SIP Trunk (FQDN: windtryst.pstn.umatilla.twilio.com:5060/UDP)
            │
            ▼   src=Twilio Signal/Media IPs (firewall groups)
WAN  ──►  UDM Pro Max ("Windroute", 28704e203ed4)
            │     ├─ Port-forward UDP 6767       → 10.10.199.1 (UDM Default VLAN IP)
            │     └─ Port-forward UDP 10000-60000 → 10.10.199.1 (RTP media)
            ▼
        UniFi Talk service (controller v5.1.2, listens on TCP 3419 + SIP UDP 6767)
```

The two UDM port-forwards (read-only audit `/tmp/unifi-state/port-forwards.json`):

| Name | Proto | Dst port | Forward target | Source restriction (firewall group) |
|---|---|---|---|---|
| `Twilio-SIP` | UDP | `6767` | `10.10.199.1:6767` | **"Twilio Signal IPs"** (`6499f5c3…`) — 8 × /30 regional signalling CIDRs |
| `Twilio-Media-Signal` | UDP | `10000-60000` | `10.10.199.1:10000-60000` | **"Twilio Media IPs"** (`6499f50a…`) — `168.86.128.0/18` |

Trunk transport in this era was **UDP** — not TLS, not 5061. SIP signalling was unencrypted on the
WAN; Twilio authenticated outbound via the source-IP ACL on the trunk (no SIP REGISTER,
`register: "false"`), inbound via the Talk-side ACL CIDR list.

**Why it was abandoned:** Talk's built-in 3rd-party-SIP listener is fragile and has no IaC holding
its WAN port open. It **died on the 2026-06-05 UDM firmware update** — nothing in
port-forward/firewall/IaC kept its WAN port reachable, so inbound broke silently.

**Now:** the external Twilio leg terminates on the **asterisk-sbc** (VM 1004, `10.10.201.40`) over
**TCP 5061 (SIP-TLS) + UDP 10000-20000 (sRTP)**, which bridges internally to UniFi Talk on
`10.10.199.1:6767`. The live UDM port-forwards (`Twilio-SIP`, `Twilio-Media-Signal`) now target
`.40`. The old `Allow-Twilio-SIP-6767` / `Allow-Twilio-Media-10000-60000` user firewall rules are
**vestigial** (cleanup candidates) — external Twilio no longer hits `:6767` on the UDM. Source of
truth for the external leg: `infra/ansible/playbooks/asterisk-sbc.yml` (+ the PVE firewall scoping
in `infra/terraform/proxmox/firewall/standalone-vms.tf`, M77 Stage-2b). See the live doc for the
current architecture.

## Migration: UDP → TLS+sRTP (task #22 / #80)

**Step 1 — restore inbound routing + TLS signalling (DONE 2026-05-27):**

- CF DNS A record `sip.wind.etherport.net` → `47.159.189.5` (UDM WAN) added to
  `cloudflare/variables.tf` dns_records_a.
- Windtryst trunk Origination URL set to
  `sips:sip.wind.etherport.net:5061;transport=tls` (replacing a dead legacy host
  that had silently broken inbound).
- UDM-side: proxy flipped to port 5061 + Custom Field `register-transport: tls`
  in the UniFi Talk 3rd-party SIP config (UI change; no IaC for Talk yet).
- `secure=false` on the Twilio trunk stays — sRTP support missing on UniFi Talk
  would break calls under `secure=true`.

**Step 2 — full TLS+sRTP (the SBC — this is what shipped, see live doc):**

- UniFi Talk does not support sRTP (multi-year open feature request), so full secure trunking
  (`secure=true` on the Twilio trunk) is impossible terminating directly on Talk.
- Workaround chosen: an SBC (Asterisk PJSIP) between Twilio (TLS+sRTP) and UDM/Talk (plain
  RTP/UDP over the LAN). This is the **asterisk-sbc** that now runs in production.
- Alternative (not taken): wait for Ubiquiti to ship sRTP, then flip Twilio `secure=true`.

**IaC for UniFi Talk config:** the Talk half remains UI-managed (the `paultyng` TF provider doesn't
model Talk). The SBC half is fully IaC (`asterisk-sbc.yml`), which is what gives the external leg a
durable, firmware-update-survivable edge.

## Twilio-side history

- 2026-05-26: Released `+19094141003` (orphan secondary Talk DID). Detached from
  trunk via trunking endpoint; SDK DELETE succeeded.
- 2026-05-26: Deleted duplicate Cabin emergency address `ADa91ea9`. Original
  `AD1fe17` retained — it's the one attached to the keeper DID.
- 2026-05-27: SIP origination URL migrated to
  `sips:sip.wind.etherport.net:5061;transport=tls` (TLS signalling, cleartext
  RTP). Restored inbound routing AND encrypted signalling. Full TLS+sRTP was
  blocked by UniFi Talk → task #80 (SBC).
- Earlier: the previous origination host had been silently broken for inbound for
  an unknown period (delegated to AWS NS but no hosted zone). Likely few/no
  inbound calls noticed.
