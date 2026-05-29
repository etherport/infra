# Firewall Zones — Future-State Design and Migration Plan

**Date:** 2026-05-23 (revised 2026-05-27 with §7 + §9 decisions resolved).
**Status:** Decisions resolved; execution starts at the Pre-flight section.
**Source material:** previous (aspirational) `docs/architecture/firewall-zones.md`, plus `docs/planning/udm-audit-2026-05-23.md` Part 1 §1.2 and P3 #20.
**Tracker:** companion to **M30** in `docs/planning/outstanding-work.md`.

---

## 1. Why this doc exists

The 2026-05-23 audit confirmed that the firewall zone design described in older versions of `docs/architecture/firewall-zones.md` was never implemented. Only one custom zone (`IoT`) exists on the UDM; sensitive networks (Servers/201, Security/205, vSAN/209, Ceph/210, Unifi/212, Inter-VLAN/4040) all sit in the built-in `Internal` zone with `Internal → Internal: Allow All Traffic` as the default.

### 1.1 Corrections from live inspection (2026-05-28)

Three assumptions in earlier revisions of this doc were wrong; they're corrected here once so subsequent sections don't propagate them.

**The UDM is multi-homed; "the UDM IP" is not 10.10.200.1.** From the live `/stat/device` record for `Windroute`: `lan_ip = "10.10.199.1"`, with 11 ethernet interfaces. The UDM hosts an SVI (`.1` of each UDM-routed /24). Its canonical identity in UniFi terms is `10.10.199.1` (the Default-VLAN interface, which is also where Talk SIP listens on UDP/6767). `10.10.200.1` is just the SVI we happen to route management UI access through. **Firewall implication:** traffic destined to any UDM SVI is policed by the `Gateway` built-in zone (UniFi's INPUT-chain analogue), regardless of which SVI IP was hit. So the `Router-Gateway` IP group is of limited use as a *destination* matcher in `Internal → *` rules — UDM destinations are matched by zone, not by IP.

**VLAN 212 (Unifi) does NOT contain APs or switches.** Live client/device dump shows:
- **VLAN 200 (Management)** — 16 admin-class devices: UDM Pro Max + **all 7 APs** + **all 9 switches** + UPS1/2 + PDU1/2 (per `/stat/device` + `/stat/sta`).
- **VLAN 212 (Unifi)** — 18 appliance-class clients: **3 UVP-TOUCH Talk phones** (.250/.100/.114) + **~13 UniFi Protect cameras** (workroom, basement, driveway-lower/mid/upper, living-room, path, chapel, access-road, deck, front-door, gate) + **UA-Gate + UA-Intercom** (UniFi Access) + **Protect controller at .10**.

The 17 + 18 = 35 figure matches the UniFi Network console's unified "Devices" view (Network-app-managed + infrastructure clients). The Network app uses `/stat/device` for the former (17) and `/stat/sta` for the latter (18); the UI merges them.

**L3 routing is split between UDM and Switch Rack PoE — the audit was right, an earlier revision of this doc was wrong.** A revision dated 2026-05-27 claimed "all 9 switches are L2-only because `config_network.type=dhcp`" and used that to dismiss the audit's L3-switch concern. The `config_network.type` flag is just about how the switch's *own management* IP is assigned (DHCP vs static), not whether the switch performs L3 routing. The actual L3 topology, from `/rest/networkconf`:

| VLAN | Routed by | `gateway_type` | Notes |
|---|---|---|---|
| Default/199, Management/200, IoT/204, Security/205, Guest/206, Unifi/212 | **UDM** | `default` | Visible in UDM zone-picker; UDM zone firewall applies |
| Servers/201, Clients/202, vSAN/209, Ceph/210 | **Switch Rack PoE** (US624P @ `10.10.200.232`, MAC `d8:b3:70:75:eb:df`) | `switch` | Hidden from UDM zone-picker because UDM doesn't route them |

Corroborating evidence: `/rest/routing` has `(L3)` static-route variants (`AWS Environment (L3)`, `WG Tunnel (AWS) (L3)`, `WG Client Tunnel (L3)`) — UniFi auto-pushes these to whichever switch is configured as an L3 router. The `(L3)` versions wouldn't exist if no switch were L3.

**Architectural implication — the network is a textbook hybrid.** Switch-routed VLANs form the "compute+storage fabric"; UDM-routed VLANs are the "policy zones". This is the standard enterprise DC pattern (firewall handles north-south + security zones; L3 switch handles east-west at line rate for storage + compute). It is the right shape for this workload because:

- The **Switch Rack PoE has ~50 Gbps non-blocking fabric** with ASIC-based line-rate L3 forwarding. The UDM Pro Max is CPU-bound at ~3.5 Gbps with IDS/IPS, ~5 Gbps without.
- **Storage flows** (vSAN replication, Ceph backfill on jumbo-MTU) regularly burst to 8+ Gbps. Routing them through UDM would collapse throughput.
- **Workstation → NAS** flows (Clients/202 video editor pulling from vSAN/NAS) also need 10G line-rate. Clients/202 staying switch-routed preserves that.

**Phase-plan implication — Phases 2 and 4 need re-scoping.** vSAN/Ceph + Servers/Clients all stay switch-routed (performance reasons). Their inter-VLAN security is governed by switch ACLs (the M52 workstream — now elevated from "placeholder until needed" to "primary east-west enforcement mechanism"), not by UDM zone policies. UDM zone policies still apply for any traffic from these VLANs that *leaves the switch fabric* (north-south, or crossing to UDM-routed VLANs). See §3 Phase 2 + Phase 4 for the revised approach.

**Phase 1 implication:** the original rule design ("Mgmt → Unifi on adoption ports 8080/3478") was too narrow because the devices on 212 are *not* APs/switches doing inform/STUN — they're cameras streaming RTSP, phones doing SIP/RTP, Access devices doing their own protocols, and admin laptops hitting `.10:443` for the Protect UI. Phase 1 rules below use 4 broad zone allows preserving current connectivity. Tightening is a follow-up pass after a flow-observation window. *(VLAN 212 is UDM-routed (`gateway_type: default`), so Phase 1 itself is unaffected by the L3-split correction.)*

We had two options:

- **(A)** Implement the aspirational design — create custom zones, move networks in, codify per-flow allow rules.
- **(B)** Rewrite the doc to describe the live single-zone reality and stop pretending.

The audit recommended **(B) now + (A) later as a properly-planned migration**. The architecture doc has been rewritten per (B). This doc captures (A) — what the multi-zone end-state should look like and the phased path to get there, so the migration can be sequenced into `outstanding-work.md` when the user is ready.

---

## 2. Proposed end-state

### 2.1 Custom zones

| Zone | Trust | Member networks | Rationale |
|------|-------|-----------------|-----------|
| `Trusted` | High | Management/200, Servers/201, Clients/202 | Primary admin + service + user networks. Wide reach by design. |
| `Infrastructure` | High (restricted) | Unifi/212, Inter-VLAN/4040, vSAN/209, Ceph/210 | Equipment and storage networks. Should not reach the internet on their own, should not be reachable from less-trusted zones. |
| `IoT` (already exists) | Low | IoT/204 | Smart-home gear. Internet + DNS only. |
| `Security` | Isolated | Security/205 | SimpliSafe / future camera gear. Most-isolated zone. |

Built-in zones stay as-is: `External` (WAN), `Gateway` (UDM itself), `VPN` (WG remote-user pool — only if/when re-enabled), `Hotspot` (Guest/206), `DMZ` (unused).

**Networks intentionally left in `Internal`:** none. Once the migration completes, the `Internal` built-in zone should have **no member networks** — every LAN VLAN gets a deliberate custom-zone assignment.

> Note: VLAN 4040 (Inter-VLAN transit) is on the boundary between `Trusted` and `Infrastructure`. We place it in `Infrastructure` since it carries pure transit traffic between routers; users and services should never source from 4040.

### 2.2 Inter-zone allow/deny matrix (proposed defaults)

Rows = source zone, columns = destination zone. `A` = Allow All, `B` = Block (default), `B+R` = Block with named allow rules listed below the matrix.

| Source ↓ / Dest → | Trusted | Infrastructure | IoT | Security | Hotspot | External | Gateway | VPN |
|---|---|---|---|---|---|---|---|---|
| **Trusted** | A | B+R | B+R | B+R | **B** | A | A | A |
| **Infrastructure** | B+R | A | B | B | B | **B** | A | B |
| **IoT** | B+R (DNS only) | B | A | B | B | A | A (return) | B |
| **Security** | B+R (DNS only) | B | B | A | B | **B** | A (return) | B |
| **Hotspot** | B+R (portal/DNS only) | B | B | B | A | A (post-auth) | A (DHCP/DNS only) | B |
| **External** | B+R (Twilio, WG inbound) | B | B | B | B | A | B+R (Twilio, WG) | B |
| **VPN** | A | B+R | B | B | B | A | A | A |

### 2.3 Named allow rules implied by the matrix

These replace what the aspirational doc enumerated. Wherever possible, use Firewall Groups (`Settings > Profiles > Network Objects / Port Groups`) rather than hard-coded IPs.

> **Note:** these per-flow named rules are the **target end-state** — they'll land in tightening passes after each phase has soaked. Phase 1 itself uses 4 broad zone-allows (see §3 Phase 1) rather than these specific port-level rules, because the device inventory on VLAN 212 (Protect/Talk/Access — see §1.1) needs many more flows than just adoption ports. Same pattern likely applies to later phases.

**Trusted → Infrastructure:** *(Phase 1 ships broad allows; replace with these in a tightening pass)*
- `Trusted-to-Protect-UI`: Management/200 + Clients/202 → Protect controller (`10.10.212.10`) TCP 443 (Protect web UI + API)
- `Trusted-to-Talk-Admin`: Management/200 → UDM Gateway HTTPS 443 (Talk admin lives on the UDM, accessed via Network app)
- `Trusted-to-UA-Admin`: Management/200 → UA-Gate/UA-Intercom HTTPS 443 (device admin UIs)
- `Servers-to-Ceph`: Servers/201 → Ceph/210 all — **N/A for UDM zone policy**: both VLANs are switch-routed (per §1.1), so this flow stays on the switch fabric and is governed by M52 switch ACLs, not UDM rules. Documented here only for the M52 design pass.
- `Mgmt-to-Storage`: Management/200 → vSAN/209 on TCP 22, 80, 443, 8006 (Proxmox admin) — **crosses UDM** (Mgmt is UDM-routed, vSAN is switch-routed); UDM zone policy applies.

**Trusted → IoT:**
- `Trusted-to-Hue`: Clients/202 → IoT/204 (Hue bridge IPs) TCP 80, 443, 8080 (intentional — Hue app on phones can talk directly to the bridge as a fallback when HA is down or for features HA doesn't expose).
- *Note:* Home Assistant's web UI is on **Servers/201** (K8s pod via Traefik IngressRoute). Clients access HA via the in-Trusted-zone Traefik LB IP, which doesn't cross zones — handled by the intra-Trusted Allow All default. The `10.10.204.25` macvlan IP on HA is the pod's *outbound* presence into IoT/204 (so HA can talk to Hue/Zigbee/Z-Wave directly); clients should NOT use it to reach the HA UI.

**Trusted → Security:**
- `Trusted-to-Security-Mgmt`: Management/200 → Security/205 TCP 22, 80, 443 (admin reach)

**IoT → Trusted (already live):**
- `Allow IoT to DNS`: IoT/204 → `DNS-Servers` (10.10.201.5, .6) TCP/UDP 53

**Security → Trusted:**
- `Security-to-DNS`: Security/205 → `DNS-Servers` TCP/UDP 53
- (Optional) `Security-to-NTP`: Security/205 → 10.10.200.1 UDP 123 — only if SimpliSafe gear ever drifts

**External → Internal / Gateway (already live):**
- `Allow-Wireguard`: External UDP → 10.10.201.20:9821
- `Allow-Twilio-SIP-6767`: External UDP (Twilio Signal IPs) → Gateway UDP 6767
- `Allow-Twilio-Media-10000-60000`: External UDP (Twilio Media IPs) → Gateway UDP 10000-60000

**VPN → Infrastructure (only if VPN pool ever populated):**
- `VPN-to-Mgmt`: VPN → Management/200 TCP 22, 443 (admin reach)
- VPN → vSAN/Ceph: deny — VPN clients have no business in storage networks

### 2.4 Firewall groups to create alongside the migration

Per audit §2.1, only 3 IP groups + 2 port groups exist today. The migration should add the rest in one pass so per-rule definitions stay clean:

IP groups: `Management-Network` (200), `Servers-Network` (201), `Client-Network` (202), `IoT-Network` (204), `Security-Network` (205), `vSAN-Network` (209), `Ceph-Network` (210), `Unifi-Network` (212), `Home-Assistant` (HA Multus macvlan IPs across 202/204/205), `Router-Gateway` (10.10.200.1 + 10.10.199.1 — the latter is the UDM's canonical `lan_ip`; see §1.1), `AWS-Networks` (10.10.100.0/22, 10.255.255.0/29, 10.254.0.0/24).

Port groups: `NTP-Port` (123), `HomeAssistant-Port` (8123), `UniFi-Adoption-Ports` (8080, 3478).

> **2026-05-28 caveat on `Router-Gateway`:** in UniFi v10's zone model, traffic *destined to* any UDM SVI is policed by the built-in `Gateway` zone, not by the zone where the IP's subnet lives. So `Router-Gateway` is of limited use as a **destination** matcher in zone-based rules — `dest zone = Gateway` covers all UDM-IP destinations regardless of which SVI. The group is still useful for *source* matching (rare — UDM rarely originates flows in firewall scope) and for documentation/readability. Don't fight it; leave it created. *Status 2026-05-28: ✅ created via `udm-firewall.yml` commit `3271cea`.*

---

## 3. Phased migration plan

Each phase = a single PR (doc update + change-log entry) + a single maintenance window. Risks per phase are listed; rollback is at the end of each phase description.

### Pre-flight (before Phase 1)

- [ ] **UDM backup automation landed (M31).** Do not start without it — the entire firewall config lives only on the UDM, and any mistake in a phase below needs a restore path.
- [ ] **Out-of-band recovery confirmed.** SSH to the UDM via WAN-side WireGuard works (i.e., a flat-out broken firewall rule won't lock you out of the box). Test: from the AWS edge, `ssh -J <wg> SmrO5ui09e@10.10.200.1` (or `@10.10.199.1` — both UDM SVIs work) succeeds. Note: any UDM SVI is reachable for SSH — pick whichever VLAN your OOB jump host can route to.
- [ ] **Firewall groups created (P2 #12).** Pure-additive; do this in its own micro-PR before any zone moves so subsequent phases can reference groups instead of CIDRs.
- [ ] **Network Isolation cleared on Security/205 (or move-with-isolation decision documented).** Today it's ON; if you leave it on after Security becomes a custom zone, the Security-to-DNS allow rule will never fire (audit §1.9, Known anomaly #1).
- [ ] **Audit `External → Gateway` boilerplate.** UniFi auto-populates ~13 predefined allows here (DHCPv6/RA/RADIUS/etc.). The migration adds nothing to that cell; just don't accidentally delete them.

### Phase 1 — Pilot: move Unifi/212 into `Infrastructure`

**Why first:** Bounded blast radius and clear failure signals. VLAN 212 carries the Protect/Talk/Access appliance fleet (per §1.1 correction): **3 Talk phones, ~13 Protect cameras, UA-Gate + UA-Intercom, Protect controller at .10**. APs/switches are NOT on 212 — they're on Management/200 and are completely unaffected by Phase 1. Failure modes are user-visible and quickly diagnosed: phones lose registration (no calls in/out), cameras drop from Protect UI, Access devices stop responding to swipes.

**Rule design philosophy (revised 2026-05-28):** start broad — Phase 1's structural goal is zone topology, not service tightening. Enumerating every Protect-camera/Talk-phone/UniFi-Access flow up-front is expensive and error-prone given how many protocols those appliances use. Save tightening for a follow-up phase after observing flows in the new zone for ~1 week.

**Steps:**

1. Create custom zone `Infrastructure` with **no member networks** (empty). Pre-staging the rules below before moving VLAN 212 in means rules are no-ops until step 7; if any rule is mis-configured, the implicit Internal→Internal allow is still protecting everything.
2. **Rule 1** `Internal → Infrastructure`: source=Internal/Any, dest=Infrastructure/Any, port=Any, action=Allow. Covers admins on Mgmt + future Servers/Clients monitoring of cameras and Protect events reaching 212 devices.
3. **Rule 2** `Infrastructure → Internal`: source=Infrastructure/Any, dest=Internal/Any, port=Any, action=Allow. Covers 212 → Servers flows like Talk phones forwarding syslog to Alloy LB at `10.10.201.73`.
4. **Rule 3** `Infrastructure → Gateway`: source=Infrastructure/Any, dest=Gateway/Any, port=Any, action=Allow. Covers all UDM-service traffic — DHCP/DNS/NTP/SIP-on-UDP/6767/RTP-on-UDP/10000-60000/Talk/Protect API/etc. — regardless of which UDM SVI a 212 device hits. Per §1.1, Gateway is the right destination zone for UDM-IP traffic, NOT Internal.
5. **Rule 4** `Infrastructure → External`: source=Infrastructure/Any, dest=External/Any, port=Any, action=Allow. Covers UniFi cloud, STUN, firmware update fetches by cameras + phones + Access devices.
6. Verify rules saved + visible in the policy list. They match nothing yet (VLAN 212 still in Internal).
7. **Moment of truth:** edit the `Infrastructure` zone → add `Unifi` (VLAN 212) to member networks → save.
8. Watch for 5-10 minutes:
   - UniFi → Devices: APs/switches stay `Connected` (sanity check — Phase 1 doesn't touch them, but a typo could).
   - Protect UI loads + cameras show as `Online`.
   - Talk phones stay `Online` in Talk dashboard.
   - Functional test: place a call from one UVP-TOUCH; verify it rings and audio is two-way.
   - Functional test: load a camera live feed; confirm video.

**Risks:**
- Talk phones lose SIP registration → inbound calls fail.
- Protect cameras drop from controller → recordings stop.
- UniFi Access devices stop responding → physical access via UA-Gate/UA-Intercom breaks.
- Functionally equivalent rules to today's Internal→Internal allow should preclude this; risk is from rule typos, not design.

**Rollback criteria:** any 212 device stays `disconnected` for >5 min after the move.

**Rollback procedure:** edit `Infrastructure` zone → remove `Unifi` from member networks → save. VLAN 212 returns to Internal, implicit Internal→Internal Allow All resumes. The 4 rules can stay (they're no-ops with nothing in Infrastructure) or be deleted in a cleanup pass.

**Tightening pass (Phase 1.5, after Phase 1 soak ≥7 days):** replace the 4 broad allows with per-flow named rules based on observed traffic (UniFi Insights → Traffic + Loki query of UDM syslog for any blocked flows during Phase 1). Likely targets: Internal→Infrastructure on TCP/443 (Protect UI) + TCP/8843 (Protect direct) + camera RTSP ports + Talk SIP/RTP from UDM. Skipped at Phase 1 to keep blast radius bounded.

---

### Phase 2 — vSAN/209 + Ceph/210 stay switch-routed; UDM-zone move is DROPPED. Replace with M52 design.

**Status: REWRITTEN 2026-05-28** after live-state inspection corrected the L3-routing picture (see §1.1). The original "move vSAN/Ceph into Infrastructure zone" plan can't be executed via the UDM UI — these VLANs have `gateway_type: switch` (routed by Switch Rack PoE), and the UDM zone picker correctly hides them because UDM zone policy doesn't fire for switch-routed traffic.

**Why we keep them switch-routed instead of flipping to UDM-routed:**

- vSAN replication regularly hits 8+ Gbps at MTU 9000.
- Ceph backfill on 10G is similar.
- UDM Pro Max forwards at ~3.5 Gbps with IDS/IPS, ~5 Gbps without — would halve effective storage throughput.
- The L3 switch ASIC forwards at line rate (≈50 Gbps non-blocking fabric).

**What replaces this phase:** the M52 workstream — an Ansible playbook managing L3 switch ACLs on Switch Rack PoE (US624P @ 10.10.200.232). The ACLs become the primary security enforcement for all switch-routed inter-VLAN traffic.

**M52 ACL scope (target end-state):**

| Source → Dest | Decision | Rationale |
|---|---|---|
| Servers/201 ↔ Clients/202 | Allow (most) | Same trust tier; admin SSH, K8s service access, ArgoCD UI, etc. |
| Servers/201 → vSAN/209 | Allow | K8s PV mounts; Proxmox node ↔ NAS shares |
| Servers/201 → Ceph/210 | Allow | K8s Ceph RBD mounts; CNPG PVCs; etc. |
| Clients/202 → vSAN/209 | Allow | Video-editing workstation pulling from NAS; SMB/NFS shares |
| Clients/202 → Ceph/210 | Deny (default) | No legitimate client workflow needs raw Ceph |
| vSAN/209 ↔ Ceph/210 | Deny | Distinct storage backends; no cross-talk |
| Any switch-routed → External (via UDM) | Allow | Standard north-south egress through firewall |

**Phase 2 deliverables (replacing the old "move to Infrastructure zone" steps):**

1. **Switch ACL audit** — pull current port profiles + any in-place ACLs on Switch Rack PoE via UI screenshots or `/proxy/network/api/s/default/rest/portconf` + `/rest/firewallrule` at the switch level. Capture into `docs/architecture/l3-switch-state-2026-05-28.md`.
2. **M52 design doc** — `docs/planning/l3-switch-acl-iac-2026-05-28.md`. Defines: the ACL matrix above, the API endpoints used to apply ACLs to a UniFi USW (per-port vs per-VLAN), test methodology, rollback procedure.
3. **M52 playbook** — `infra/ansible/playbooks/usw-acls.yml`. Follows the same auth pattern as `udm-firewall.yml` (1Password tf-admin item → API token → /proxy/network/...). Reconciles a declarative ACL list.
4. **M52 apply + soak** — apply the ACL set, soak for ≥7 days, monitor for breakage (K8s PV mount errors, NAS access failures from Clients laptops, Proxmox health drift).

**Risks:**
- Switch ACLs are stateless — return traffic needs explicit allows in the reverse direction unless using "established" tracking (USW ACL features vary by model).
- Misconfigured ACL can cut K8s ↔ Ceph and trigger CNPG / Velero failures within minutes.
- Rollback: revert ACL list via playbook re-run with previous spec, or UI-delete if total revert needed.

**Pre-flight before applying M52:**
- M31 backup ✓ (already covered).
- Switch ACL feature-set confirmed for US624P firmware version (some USW models only have per-port ACLs; some support per-VLAN; some support "stateful" semantics via paired rules).
- Test ACL on a sacrificial VLAN flow first (e.g., a low-impact deny rule that we can verify takes effect and revert).

**Original Phase 2 (kept for history; do not execute):**

> ~~Add VLAN 209 and VLAN 210 to existing `Infrastructure` zone. Add `Mgmt-to-Storage` allow in `Internal → Infrastructure`. Verify Proxmox cluster + Ceph health stays green for 24 h.~~ Cannot be done via UI; UDM zone picker hides switch-routed networks. Even if forced via API, UDM zone policy wouldn't fire for intra-switch traffic, so the rules would be no-ops.

**Steps:**

1. Add VLAN 209 and VLAN 210 to existing `Infrastructure` zone.
2. Add `Mgmt-to-Storage` allow in `Internal → Infrastructure`.
3. Verify Proxmox cluster + Ceph health stays green for 24 h.
4. Confirm K8s nodes still mount Ceph PVs (any kube workload writing to RBD).

**Risks:**
- If any cross-VLAN admin path (e.g., a script SSHing from Clients/202 to a vSAN host) was implicitly relying on `Internal → Internal: Allow All`, it now breaks.
- The L3 switch ACLs (audit §1.9) are unverified — if a switch-side allow was masking a UDM-side block, that's invisible until something fails.

**Rollback criteria:** Proxmox/Ceph health degrades, OR any in-cluster PV mount fails.

**Rollback procedure:** remove 209 + 210 from `Infrastructure`, return them to Internal.

---

### Phase 3 — Create `Security` zone and move VLAN 205 ✅ DONE 2026-05-28

> **Completed 2026-05-28.** Security custom zone created; VLAN 205 moved in; legacy `network_isolation_enabled` retired (zone model is now sole enforcement). Verified: 0 legacy `Isolated Networks` rules remain, 7 zone-default blocks active, `→External`+`→Gateway` allows intact, 3/3 SimpliSafe devices healthy, SimpliSafe app confirmed online. Net behavior change: zero — isolation moved from legacy toggle to zone model + gained automatic IoT separation. DHCP DNS untouched; External never blocked (wifi-primary preserved).



**Live state inspection (2026-05-28) overturned two assumptions** the original plan was built on:

| Original assumption | Reality (from `/rest/networkconf`) |
|---|---|
| "Set DHCP DNS to .5/.6" (implies SimpliSafe needs internal DNS) | `dhcpd_dns_enabled: False`, DNS fields empty — and SimpliSafe **works today** without internal DNS. It resolves via the UDM gateway (`10.10.205.1`, a Security→Gateway flow) or hardcoded public DNS (Security→External). Neither needs an internal DNS allow. **Don't touch DHCP DNS.** |
| "Security → External = Block (SimpliSafe phones home via cell)" | User confirmed SimpliSafe is **wifi-primary + cell-backup**. Blocking External would force it onto cell permanently (degraded, possible carrier cost). **Security → External must stay ALLOW.** |

**What's actually on 205:** 3 SimpliSafe devices only (base station `10.10.205.135` + 2 others, all `18:93:7f`/SimpliSafe OUI). `network_isolation_enabled: True` already blanket-blocks 205 from all other LANs — so 205 is *already* effectively a deny-all-internal + allow-internet zone. The migration's job is to express that in the **zone model** (clean, single source of truth) instead of the legacy per-network isolation toggle.

**Why a custom zone is functionally equivalent to today + cleaner:** a new custom zone defaults to `→ External: Allow`, `→ Gateway: Allow`, `→ everything-else: Block` (confirmed with Infrastructure in Phase 1). That's exactly SimpliSafe's needs (internet for monitoring + UDM for DHCP/DNS, nothing internal). Moving 205 into a `Security` zone reproduces the current isolation in the modern model — then we retire the legacy toggle so there's one mechanism to reason about.

**Steps (sequenced to avoid any exposure window):**

1. Create custom zone `Security` with **no members** (empty).
2. Move VLAN 205 into `Security`. Now 205 is **double-protected** (legacy network-isolation AND zone-default-block both active) — there is never a moment of exposure.
3. Verify SimpliSafe stays online: base station `.135` + 2 devices keep fresh `last_seen`; **user confirms the SimpliSafe app shows the system online + responsive** (arm/disarm test from the app).
4. **Only after step 3 passes:** turn OFF `network_isolation_enabled` on Security/205 (Settings → Networks → Security → Advanced → Network Isolation). The zone-default-block now solely enforces isolation. Re-verify SimpliSafe still online + app responsive.
5. Do **NOT** add a Security→DNS allow (not needed — DNS works via Gateway/External). Do **NOT** change DHCP DNS. Do **NOT** block Security→External.
6. *(Optional, deferred)* If admin reach into 205 is ever needed (e.g., to hit a SimpliSafe device web UI from a laptop), add a narrow `Internal → Security` allow then. Not needed today.

**Risks:**
- HA has a Multus macvlan presence on 205 (`10.10.205.25`) but SimpliSafe integration is cloud-API based (Servers/201 → External), not local — so the zone move doesn't affect HA↔SimpliSafe. Intra-VLAN HA↔device traffic (if any) is L2 and unaffected.
- If SimpliSafe turns out to need some internal flow we haven't observed, the symptom is the app showing the system offline — recoverable via rollback.

**Rollback criteria:** SimpliSafe app shows system offline / unreachable for >5 min, OR base station `last_seen` goes stale.

**Rollback procedure:** move VLAN 205 back to Internal zone; if step 4 was done, re-enable `network_isolation_enabled`. Returns to current working state.

---

### Phase 4 — REVISED: Trusted = Mgmt/200 only (or skip entirely)

**Status: REWRITTEN 2026-05-28** following the L3-routing correction in §1.1. Servers/201 + Clients/202 both have `gateway_type: switch` (routed by Switch Rack PoE) so they CANNOT be assigned to a UDM custom zone via the UI for the same reason vSAN/Ceph can't (Phase 2). Their inter-VLAN security is governed by M52 switch ACLs, not UDM zone policy.

**That leaves Management/200** as the only "humans-administering-machines" VLAN that's UDM-routed. The question becomes: is the symbolic value of a custom `Trusted` zone containing only VLAN 200 worth the work?

**Option A — Skip Phase 4 entirely.** Leave Management/200 in the built-in `Internal` zone. Internal already has the right policy posture for an admin VLAN: Allow to External (admin web access), Allow to Gateway (UDM services), and the cross-zone allows we'll add in Phase 3 etc. Renaming Internal to Trusted is purely cosmetic — same policies apply. **Recommended.**

**Option B — Create `Trusted` zone with VLAN 200 only.** Move Mgmt out of Internal. Forces every cross-zone allow to be re-expressed against Trusted instead of Internal. No security gain; just label hygiene. Could be done in a separate cleanup PR if you find the "Internal" name annoying once Servers/Clients are no longer in it.

**Recommendation:** go with **Option A**. Mark Phase 4 as `SKIPPED — not necessary` in Phase 5 cleanup and proceed straight from Phase 3 (Security zone) to Phase 5 (cleanup).

**Original Phase 4 (kept for history; do not execute):**

> ~~Create custom zone `Trusted` with VLANs 200, 201, 202. Confirm zone default `Trusted → Trusted: Allow All`. Configure outbound, inter-zone allows, smoke-test kubectl + ArgoCD + UDM UI from a Clients laptop.~~ Not executable — Servers/201 and Clients/202 are switch-routed and won't appear in the UDM zone picker. Their security is M52's responsibility.

**Rollback criteria:** UDM UI unreachable from Clients, K8s API unreachable, MetalLB VIP unreachable, OR any in-house user reports loss of internet.

**Rollback procedure:** move 200/201/202 back to Internal zone in the reverse order. If that fails, restore from the most recent S3 UDM backup (M31).

---

### Phase 5 — Cleanup and verification

After all four phases complete:

1. Confirm built-in `Internal` zone has **no member networks** (Default/199 stays — see #5 below).
2. Delete any leftover predefined Internal-to-X policies that no longer make sense.
3. Decide on Default/199:
   - Option A: keep in `Internal`, narrow DHCP scope to `.250-.254` (4-IP "rescue pool"), document.
   - Option B: move to its own `Quarantine` custom zone with deny-all everywhere except a "ping the gateway" allow.
   - Option C: delete the DHCP scope entirely.
4. Add `Internal → Hotspot: Block All` (audit P2 #11) — applies whether or not Internal still has members, since it's the catch-all for any future "untyped" network.
5. Document the new state by replacing `docs/architecture/firewall-zones.md` (again) with a description of the now-live multi-zone layout. Move this planning doc to `docs/planning/archive/`.

---

## 4. Dependencies

| Dependency | Why | Status |
|------------|-----|--------|
| **M31 (UDM backup automation)** | Hard prerequisite — without an off-box backup, no phase is safely reversible. | ✅ Live since 2026-05-23 (5 days of daily backups in S3). |
| **M30 (doc reconcile)** | Provides the current-state baseline this migration starts from. | ✅ Done 2026-05-23 (architecture/firewall-zones.md rewrite). |
| **M18 (eBGP / MetalLB BGP)** | Independent. Zone migration changes which zone owns 201, but MetalLB L2Advertisement only cares about subnet membership, not zone. | Independent — sequenced after this migration to batch UDM L3 blast-radius windows. |
| **Audit P2 #12 (firewall groups)** | Pre-flight item — groups must exist before phase 1 to keep rule text clean. | ✅ Done 2026-05-27 (commit `3271cea`) — 14 new groups landed via udm-firewall.yml. |
| **L3 switch ACL audit (audit P3 #21)** | Phase 2/4 risk is harder to bound until we know what the switch is enforcing. | **In progress (M52 workstream).** Live state (2026-05-28): Switch Rack PoE (US624P @ `10.10.200.232`) routes Servers/201, Clients/202, vSAN/209, Ceph/210 — confirmed via `gateway_type=switch` on those networks + `gateway_device` MAC matching the US624P. Currently zero ACLs in place (intra-fabric flows wide open). M52 is now the primary east-west enforcement mechanism (see Phase 2 rewrite). |
| **Identity Enterprise / RADIUS** | Not on path — skip per audit §2.7. | N/A |

---

## 5. Rollback summary

Per-phase rollback procedure (consolidated):

1. **Phase 1 (Unifi/212):** delete new allows, move 212 back to Internal. APs reconnect via default Internal-to-Internal allow.
2. **Phase 2 (vSAN/209, Ceph/210):** move 209 + 210 back to Internal. No service-side restart needed.
3. **Phase 3 (Security/205):** move 205 back to Internal, re-enable Network Isolation, blank DHCP DNS. SimpliSafe gear returns to current half-isolated state.
4. **Phase 4 (Trusted, 200/201/202):** move 200/201/202 back to Internal in reverse order. If that fails to restore (i.e., the rollback action itself is blocked by a botched rule), **restore most recent UDM backup from S3** (M31). RTO ~30 min via UI restore.
5. **Phase 5:** strictly cleanup; rollback is "leave the new state as-is and re-open the cleanup ticket."

**Total maintenance-window estimate:** 4 windows × 30-90 min each, spread across 4-6 weeks (one phase per maintenance window with at least a week of soak time between phases).

---

## 6. Decision checklist (review before kicking off)

Before opening the first PR (Phase 1), confirm:

- [ ] **M31 (UDM backup to S3) is implemented and verified** — at least one successful backup landed in S3, and one test restore was performed against a sandbox UDM or VM.
- [ ] **Out-of-band SSH path tested** — verified that I can reach the UDM (`10.10.199.1` or any other SVI) from outside the LAN (via AWS-WG path) and that a totally-broken zone rule wouldn't kill that path.
- [x] **L3 switch state captured** — 2026-05-28: Switch Rack PoE (US624P @ `10.10.200.232`) identified as L3 router for Servers/201, Clients/202, vSAN/209, Ceph/210. No ACLs currently configured (intra-fabric flows wide open by default). Original Phase 2 ("move vSAN+Ceph to UDM zone") is dropped; replaced with M52 (Ansible playbook for switch ACLs) as the primary east-west enforcement mechanism. See Phase 2 rewrite for the new workstream.
- [ ] **Firewall groups created in their own PR** (audit P2 #12) and verified rule-referencable in the UI.
- [ ] **All four phases scheduled with maintenance windows announced** to any household users who depend on the network (kids' WiFi, IP phones, alarm system, etc.).
- [ ] **Decision made on Default/199** (keep / quarantine / delete DHCP) — to be applied in Phase 5.
- [ ] **VPN zone decision made** — either delete `WireGuard WAN1` (M14) or keep with a documented `VPN → Internal` deny stance. Don't carry the "VPN → Internal: Allow All" default into the new model.
- [ ] **Decided whether to do Phase 4** at all — Phases 1-3 give most of the security benefit (untrusted networks isolated). Phase 4 (moving 200/201/202 out of Internal) is symbolic mostly, since they'd all be in one wide-open `Trusted` zone anyway. If the appetite for risk is low, **stopping after Phase 3** is a valid end state, with Trusted = Internal forever.
- [ ] **Reviewer alignment** — at least one second pair of eyes (or `claude` review pass) on the Phase 4 inter-zone allow list. Phase 4 is the only phase that can plausibly lock you out of every admin path simultaneously.

---

## 7. Decisions resolved 2026-05-27

These were originally open questions; the user's answers are captured inline as the decisions of record.

1. **SimpliSafe network dependence:** *both* wifi (primary) + cell (backup). Therefore `Security → External: Block` in Phase 3 is **risky-but-recoverable** — the alarm system has cell backup if wifi egress is cut. Phase 3 still needs a SimpliSafe-app smoke test in disarmed mode to confirm the wifi cutoff isn't silently degrading something (event lag, sensor heartbeats, etc.). Cell backup is a safety net, not a justification to skip the test.
2. **Clients/202 → Servers/201 non-K8s flows:** *none*. Phase 4 doesn't need an enumeration sweep; whatever exists today goes via documented K8s services and stays inside the Trusted zone after the move (intra-Trusted Allow All preserves the current functional state).
3. **Default/199 disposition (Phase 5):** **Option A — narrow DHCP scope to `.250-.254` rescue pool, keep in `Internal`, document.** Rationale: homelab without an onboarding/IT team. Quarantine zone (B) adds permanent firewall bookkeeping for ~0 days/year of new-device onboarding; full deletion (C) creates a debugging hole on rebuild if VLAN tags are forgotten. A 5-IP rescue pool is the documented safety hatch when something gets plugged in untagged.
4. **WireGuard WAN1 VPN pool:** *re-enable as a backup VPN path*. Rationale: hardware-failure resilience — if Proxmox + the K8s-hosted WG pod are both unreachable, the UDM-native WG server is the only remaining way in. Therefore: `VPN → *` row stays populated in the matrix (per §2.2), the `Wireguard Travel` port-forward gets re-enabled (currently `enabled: false` in live state), and Phase 5 ensures `VPN → Internal: Allow All` is *not* carried into the new model (replaced by explicit `VPN → Trusted` allow).
5. **L3-switch ACL management:** *eventually managed in code via Ansible*. Tracked as **M52** below. For Phase 2 (vSAN/Ceph zone move), this means the pre-flight L3-switch ACL capture has to actually happen (UI screenshots or `show running-config`) — otherwise Phase 2 risk is unbounded.

---

## 8. Out of scope

- eBGP between UDM and L3 switch (M18) — independent. Will follow this migration so both UDM L3 changes batch into a single blast-radius window.
- L3 switch ACL codification — tracked as **M52** (new — derived from §7.5). Pre-flight capture is in this doc; full Ansible playbook is its own project.
- Identity Enterprise / 802.1X — out per audit §2.7.
- mDNS reflector, IGMP snooping, hostname-based VPN routing — out per audit §2.5 and §2.9.
- Per-VLAN bandwidth caps on Guest — separate (audit P3 #23).

---

## 9. Design clarifications resolved 2026-05-27

These came in alongside §7 decisions; capturing the reasoning so future-you (or future-me) doesn't relitigate.

**Q1. Why is Management/200 in `Trusted` (high), not `Infrastructure`?**

The clean framing: **Trusted = "places where humans + their workstations sit." Infrastructure = "places where machines sit and need each other but not humans."** Management is humans-administering-machines, so it groups with humans.

Moving Mgmt into Infrastructure would force:
- `Infrastructure → External: Block` to be relaxed (UDM needs WAN for firmware updates / threat feeds), defeating the purpose of the Infrastructure isolation
- Every admin path Clients → UDM UI → Switches becomes a cross-zone allow (rule sprawl, ergonomic penalty)
- No actual security gain — Mgmt is where admins sit, so isolating it from Clients/Servers protects nothing the admin themselves wouldn't bypass

The UDM *itself* lives in the built-in `Gateway` zone (DHCP/DNS/NTP services on the box). The Mgmt VLAN is just the LAN segment that admins source from; it's logically separate from the UDM's own zone identity.

**Q2. Home Assistant location confirmation.**

Confirmed: **HA's main UI is on Servers/201** as a K8s pod (`home-assistant.home-automation.svc` ClusterIP `10.43.22.37:8123`, exposed via Traefik IngressRoute). The `10.10.204.25` / `.202.25` / `.205.25` IPs in HA's deployment are **Multus macvlan outbound** so the pod can reach IoT, Clients, and Security devices directly. Clients access HA's UI via the in-Trusted-zone Traefik LB — which is intra-Trusted and stays implicit-allow.

The user's stated intent on `Clients → IoT/204` for Hue is **correct and preserved**: phones running the Hue app should be able to hit Hue bridges directly as resilience against HA being down. Allow rule unchanged.

**Q3. Guest network handling.**

Already covered by the existing `Hotspot` built-in zone:
- `Hotspot → External: Allow` (post-auth) → guests get internet
- `Hotspot → Gateway: Allow` (DHCP/DNS only) → guests get DHCP/DNS from UDM
- `Hotspot → all other internal zones: Block` → guests can't reach Trusted/Infrastructure/IoT/Security

No matrix changes needed. Phase 5 adds one belt-and-suspenders rule `Internal → Hotspot: Block All` as a catch-all for any future untyped network.
