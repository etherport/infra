# 802.1X / MAB design — physically-exposed switch ports (#18, phase 2)

Status: **❌ MAB NOT ACHIEVABLE ON CURRENT HARDWARE (corrected 2026-08-02).** A prior
2026-08-01 attempt was reverted — the outdoor switches cannot enforce 802.1X/MAB (see the
CORRECTED capability matrix below). #18's real protection is Phase 0 (disabled unused
ports) + VLAN isolation + physical security. Genuine port-auth needs a hardware swap. Phase 0 (unused-port disable ×31 +
VLAN-min verification) completed 2026-07-29 via the UDM API; this doc covers the
port-authentication layer on the ports that remain *active* and physically exposed.

## Threat model (honest scope)

The attack this layer addresses: **unplug an outdoor device (camera/gate/AP), plug in an
attacker laptop, land on VLAN 212.** Today the port profile (native 212, no trunk) plus the
UDM zone firewall already bound the blast radius; port auth adds "the port won't even
forward for an unknown device."

Limits, stated plainly:
- **MAB and MAC port-security are both defeated by MAC spoofing** (the camera's MAC is on
  its sticker; an attacker who unscrews a camera can clone it). Their real value is
  stopping opportunistic/casual attachment and generating an **auth-failure signal** we
  can alert on.
- **Full 802.1X (EAP, certificate supplicants) is the only spoof-resistant option — and
  the fleet can't do it.** UniFi cameras, gate hardware, and APs have no supplicant. So
  "802.1X/MAB" here means **MAB** (MAC Authentication Bypass) or its RADIUS-less cousin,
  per-port MAC pinning.

## Hardware capability matrix (from live API inventory)

| Switch | Model | 802.1X/MAB capable? | Evidence (verified 2026-08-02 via live API) |
|---|---|---|---|
| Driveway | USF5P (Flex) | **❌ NO** | device `dot1x_portctrl_enabled=False`; zero dot1x fields on any port; UI "will not be applied" lists 802.1X |
| Access Road | USF5P (Flex) | **❌ NO** | same as Driveway (identical model) |
| Chapel | USL8LP (Lite 8 PoE) | **❌ effectively NO** | ports HAVE dot1x fields but are stuck `dot1x_mode=force_auth` (open); a `mac_based` profile + global dot1x enable did NOT translate to the port — mac_based never took |
| Outdoor Junction | USW-Flex-Mini | ❌ NO | no dot1x support at all |
| Living Room | USW-Flex-Mini | ❌ (indoor, out of scope) | — |

⚠️ **The 2026-07-29 matrix that marked USF5P/USL8LP "✅" was WRONG** — it inferred capability
from the controller ACCEPTING the profile assignment, but these switches silently drop
unsupported features (the UI "options that will not be applied" notice is the tell). None of
the outdoor switches can actually enforce MAB. The 2026-08-01 "verified end-to-end" claim was
a FALSE POSITIVE: a camera returning online after a PoE cut is exactly what happens with NO
enforcement — the reject path was never tested. All changes reverted 2026-08-02.

## The only real port-auth option: hardware
802.1X/MAB on UniFi needs a capable switch (USW-Pro / USW-Enterprise / standard USW —
NOT Flex, Flex-Mini, or Lite). To get genuine port authentication at the driveway/gate,
swap those USF5P/USL8LP units for an 802.1X-capable model; then `scripts/unifi/port-auth.py`
(profile-swap mechanism is sound) can drive it. Until then, the exposed-port protection is:
disabled unused ports (Phase 0, done + real) + VLAN 212 isolation (firewall-segmented) +
physical box security. Given the threat (opportunistic attach at an outdoor jack) and that a
plugged-in laptop lands only on the isolated camera VLAN, that posture may be sufficient
without a hardware spend — an operator call.

**Flex-Mini consequence:** Outdoor Junction can never enforce port auth. Its protection =
the port disables from phase 0 + it carries only transit (both active ports are trunks to
other switches, which we must NOT gate — dot1x on uplinks breaks everything downstream).
Accepted residual: an attacker splicing into the Junction's *transit* path is a
wire-tapping attack, which port auth wouldn't stop anyway.

## ⚠️ Phase-1 attempt finding (2026-07-29)

An inline API attempt to add `port_security_enabled` + `port_security_mac_address` to the
active edge ports FAILED SILENTLY: the controller stripped the fields on write because
those ports carry a **port profile** (`portconf_id`) — this fork won't layer per-port
MAC-security onto a profiled port via a plain `port_overrides` PUT (`setting_preference:
manual` + `portconf_id` conflict → profile wins, security dropped). No harm (ports stayed
up, all 6 cameras/gate pingable). **Conclusion:** Phase-1 needs the `scripts/unifi/
port-auth.py` helper with the correct field combination worked out (likely: drop
`portconf_id` and set the native network + security explicitly, OR use the dedicated
port-security endpoint if the fork exposes one). Do NOT brute-force via inline PUTs — the
UDM rate-limiter also trips. Verify each change downs nothing (ports stay up + camera ping).

## Options


**A. Per-port MAC pinning (port-security, no RADIUS).** Set
`port_security_enabled + port_security_mac_address:[<device MAC>]` on each exposed edge
port. No new moving parts; enforcement is switch-local; API-scriptable today (same
override mechanism as phase 0). Con: allowlist lives per-port (n places), no auth log —
a rejected MAC is silent (the device just gets no link).

**B. MAB via the UDM's built-in RADIUS (recommended target).** Per exposed edge port:
`dot1x_ctrl: "mac_based"`; per device: a RADIUS account where username=password=MAC
(UniFi's MAB convention). Central allowlist (one place), **auth failures appear in the
UDM event log → alertable** (unifi-poller / event webhook), same enforcement strength as
A. Cons: the UDM RADIUS becomes an auth dependency for camera ports (single box, but it's
also the core switch fabric — no *new* SPOF); more moving parts than A.

**C. Full 802.1X EAP.** Not applicable — no supplicant-capable endpoints on these ports.
Revisit only if supplicant-capable devices are ever placed outdoors.

## Recommendation: B, rolled out via A's data

1. **Phase 1 — pin + inventory (low risk, immediate):** apply option A (MAC pinning) to
   the 7 capable exposed edge ports. This hardens instantly AND builds the exact MAC
   inventory MAB needs. Rollback per port = clear the MAC list.
2. **Phase 2 — MAB cutover (one port first):** create RADIUS accounts for the inventoried
   MACs, flip ONE low-stakes port (Chapel p1 camera) to `dot1x_ctrl: mac_based`, soak
   48h (watch for reauth flaps — set a long reauth interval or disable periodic reauth;
   a camera that drops on every reauth is a self-inflicted outage). Then roll the
   remaining ports **in a maintenance window** — the gate/intercom ports are physical-
   access devices; a botched cutover means the gate goes dark.
3. **Phase 3 — signal:** alert on UDM 802.1X auth-failure events (unifi-poller already
   scrapes the controller; add a rule). This is the piece pinning alone can't give.

## Design details for Phase 2

- **Port list (7):** Driveway p2, p3, p4, p5*; Access Road p2, p3; Chapel p1, p2.
  (*p5 fronts multiple devices via downstream hardware — needs ALL their MACs as
  accounts; if it proves flappy, leave p5 on pinning (option A) permanently.)
- **Uplinks/transit stay `force_authorized`** (default): Chapel p8, Access Road p1,
  Driveway p1, both Outdoor Junction ports.
- **RADIUS:** built-in server (already enabled, port 1812). Accounts via
  `POST /rest/account` `{name: <mac>, x_password: <mac>, tunnel_type: 13,
  tunnel_medium_type: 6}` — no VLAN override attributes (VLAN stays from the port
  profile; RADIUS-assigned VLAN is a later refinement, not v1).
- **Failure mode:** RADIUS unreachable → port deauths on next reauth → camera dark.
  Mitigations: no periodic reauth (auth on link-up only), and the gate keeps its
  cellular/standalone function (verify before cutover).
- **Config residency / IaC:** these settings live in the UDM (not TF — the provider's
  device-import model is too heavy for per-port overrides). Durable record = this doc +
  a `scripts/unifi/port-auth.py` helper (idempotent: reads desired state from a YAML in
  repo, PUTs overrides + accounts) so the config is re-appliable and drift-checkable —
  same philosophy as `udm-firewall.yml`.

## Rollback

Per port: `dot1x_ctrl: force_authorized` (or clear `port_security_mac_address`) via one
API PUT — same mechanism, seconds to apply, no reboot. Phase-2 cutover keeps a ready-made
rollback payload per switch (captured pre-change, like the jobs.cfg snapshot pattern).
