# Firewall Zones — Future-State Design and Migration Plan

**Date:** 2026-05-23
**Status:** Proposed. No UDM config changes have been made.
**Source material:** previous (aspirational) `docs/architecture/firewall-zones.md`, plus `docs/planning/udm-audit-2026-05-23.md` Part 1 §1.2 and P3 #20.
**Tracker:** companion to **M30** in `docs/planning/outstanding-work.md`.

---

## 1. Why this doc exists

The 2026-05-23 audit confirmed that the firewall zone design described in older versions of `docs/architecture/firewall-zones.md` was never implemented. Only one custom zone (`IoT`) exists on the UDM; sensitive networks (Servers/201, Security/205, vSAN/209, Ceph/210, Unifi/212, Inter-VLAN/4040) all sit in the built-in `Internal` zone with `Internal → Internal: Allow All Traffic` as the default.

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

**Trusted → Infrastructure:**
- `Mgmt-to-Unifi-Adoption`: Management/200 → Unifi/212 on TCP 8080, UDP 3478 (UniFi inform + STUN)
- `Servers-to-Ceph`: Servers/201 → Ceph/210 all (allows in-cluster K8s if UDM ever sees it; today L3-switch-only, so this is belt-and-suspenders)
- `Mgmt-to-Storage`: Management/200 → vSAN/209 on TCP 22, 80, 443, 8006 (Proxmox admin)

**Trusted → IoT:**
- `Trusted-to-HomeAssistant`: Servers/201 + Clients/202 → 10.10.204.25 TCP 8123 (HA web UI / API)
- `Trusted-to-Hue`: Clients/202 → IoT/204 (specific bridge IP if known) TCP 80, 443, 8080 (Hue control)

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

IP groups: `Management-Network` (200), `Servers-Network` (201), `Client-Network` (202), `IoT-Network` (204), `Security-Network` (205), `vSAN-Network` (209), `Ceph-Network` (210), `Unifi-Network` (212), `Home-Assistant` (10.10.204.25), `Router-Gateway` (10.10.200.1), `AWS-Networks` (10.10.100.0/22, 10.255.255.0/29, 10.254.0.0/24).

Port groups: `NTP-Port` (123), `HomeAssistant-Port` (8123), `UniFi-Adoption-Ports` (8080, 3478).

---

## 3. Phased migration plan

Each phase = a single PR (doc update + change-log entry) + a single maintenance window. Risks per phase are listed; rollback is at the end of each phase description.

### Pre-flight (before Phase 1)

- [ ] **UDM backup automation landed (M31).** Do not start without it — the entire firewall config lives only on the UDM, and any mistake in a phase below needs a restore path.
- [ ] **Out-of-band recovery confirmed.** SSH to the UDM via WAN-side WireGuard works (i.e., a flat-out broken firewall rule won't lock you out of the box). Test: from the AWS edge, `ssh -J <wg> root@10.10.200.1` succeeds.
- [ ] **Firewall groups created (P2 #12).** Pure-additive; do this in its own micro-PR before any zone moves so subsequent phases can reference groups instead of CIDRs.
- [ ] **Network Isolation cleared on Security/205 (or move-with-isolation decision documented).** Today it's ON; if you leave it on after Security becomes a custom zone, the Security-to-DNS allow rule will never fire (audit §1.9, Known anomaly #1).
- [ ] **Audit `External → Gateway` boilerplate.** UniFi auto-populates ~13 predefined allows here (DHCPv6/RA/RADIUS/etc.). The migration adds nothing to that cell; just don't accidentally delete them.

### Phase 1 — Pilot: move Unifi/212 into `Infrastructure`

**Why first:** Lowest blast radius. Unifi/212 only carries APs/cameras/IP phones talking to the controller (UDM) on the well-known adoption + STUN ports. If something breaks, the symptom is "AP shows as disconnected in the controller" — high-signal, low-data-loss.

**Steps:**

1. Create custom zone `Infrastructure` with VLAN 212 as the only member.
2. Add allow rule in `Infrastructure → Internal` (or `Infrastructure → Trusted` if Trusted exists by then): `Unifi-Network → Router-Gateway` on `UniFi-Adoption-Ports` (8080, 3478).
3. Add allow rule in `Internal → Infrastructure`: `Management-Network → Unifi-Network` on same ports (controller-side outbound to APs).
4. Verify each AP/camera/phone re-establishes inform within 5 min (UniFi UI → Devices → status).
5. Verify UniFi Talk handsets still register (test inbound + outbound call).

**Risks:**
- APs flap if STUN/inform path breaks → captive devices drop WiFi → user-visible.
- IP phones could lose registration → inbound calls fail.

**Rollback criteria:** any AP/phone stays `disconnected` for >10 min after the change.

**Rollback procedure:** delete the new allow rules, move VLAN 212 back to Internal zone (drops the custom zone assignment), wait for inform reconnect.

---

### Phase 2 — Move vSAN/209 + Ceph/210 into `Infrastructure`

**Why second:** vSAN and Ceph traffic is **L3-switch-routed** today, so the UDM never sees the bulk of it. Moving these networks into `Infrastructure` is mostly cosmetic from the UDM's perspective — it changes which zone-default applies to the small amount of vSAN/Ceph traffic that ever reaches the UDM (e.g., a Proxmox host syncing time via 10.10.200.1).

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

### Phase 3 — Create `Security` zone and move VLAN 205

**Why third:** Security/205 currently has Network Isolation = ON + empty DHCP DNS, so it's already a half-isolated network — any breakage is bounded.

**Steps:**

1. Resolve the "Network Isolation ON / DNS blank" anomaly first:
   - Set Security/205 DHCP DNS to `.5/.6`.
   - Turn Network Isolation OFF on Security/205 (so the new zone policies apply).
2. Create custom zone `Security` with VLAN 205 as the only member.
3. Add `Security-to-DNS` allow: `Security-Network → DNS-Servers` on `DNS-Ports`.
4. Default `Security → External` = Block (SimpliSafe phones home via its own gateway, not via these IPs — verify in advance).
5. Add `Trusted-to-Security-Mgmt` allow if admin reach is needed.
6. Verify SimpliSafe base station/sensors stay armed and the SimpliSafe app still receives events.

**Risks:**
- SimpliSafe might rely on cloud egress through 205 directly — if `Security → External: Block` cuts that, the alarm goes dark. **Test in disarmed-system mode first.**
- Disabling Network Isolation on 205 mid-phase opens it to all of `Internal` for the few seconds before the zone move lands. Schedule the two steps back-to-back.

**Rollback criteria:** SimpliSafe app loses connection to base station for >5 min, OR any sensor reports `offline`.

**Rollback procedure:** move VLAN 205 back to Internal zone, re-enable Network Isolation, clear DHCP DNS — back to the live anomaly state.

---

### Phase 4 — Create `Trusted` zone and move VLANs 200/201/202

**Why fourth — and highest risk:** This is the big one. Servers/201 hosts DNS (Technitium VIP `.5`), K8s control plane, MetalLB pool, gh-runner, and most workloads. Clients/202 is every laptop in the house. Management/200 hosts the UDM itself.

**Critical pre-checks:**

- [ ] Out-of-band path verified (Phase 0 pre-flight).
- [ ] All flows currently relying on `Internal → Internal: Allow All` enumerated. Candidates to check:
  - Clients/202 → Servers/201 on every K8s service port (kubectl, ArgoCD, Grafana, Prometheus, Loki, Hubble, etc.)
  - Clients/202 → Management/200 on TCP 22, 80, 443 (UDM UI, switch UI, AP UI)
  - Management/200 → Servers/201 (admin paths, e.g., SSH to k8s nodes)
  - Servers/201 → Servers/201 (intra-zone; if Trusted is a single zone these stay implicit allow)
- [ ] Decide intra-Trusted policy: probably `Trusted → Trusted: Allow All` (functional equivalent of today's Internal-to-Internal for these three VLANs).

**Steps:**

1. Create custom zone `Trusted` with VLANs 200, 201, 202.
2. Confirm zone default `Trusted → Trusted: Allow All` (UniFi default for intra-zone).
3. Configure outbound: `Trusted → External: Allow All` (no change from today).
4. Configure inter-zone allows as enumerated in §2.3.
5. Smoke-test from a Clients/202 laptop: kubectl reaches the cluster, ArgoCD UI loads, SSH to k8s nodes works, UniFi controller UI loads.
6. Smoke-test from a Servers/201 host: outbound internet works, NTP works, cluster-internal flows work.

**Risks:**
- This is the phase that can lock you out of UDM management if a `Trusted → Gateway` rule is mis-configured.
- MetalLB ARP advertisement is L2 on VLAN 201; zone move shouldn't affect it but worth watching `kubectl get svc -n metallb-system` for any flapping.
- Any forgotten cross-VLAN allow (e.g., a backup job from a Clients/202 machine to a Servers/201 NFS export) silently breaks.

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
| **M31 (UDM backup automation)** | Hard prerequisite — without an off-box backup, no phase is safely reversible. | Open. **Block migration on this.** |
| **M30 (doc reconcile)** | Provides the current-state baseline this migration starts from. | Done as of 2026-05-23 (architecture/firewall-zones.md rewrite). |
| **M18 (eBGP / MetalLB BGP)** | Independent. Zone migration changes which zone owns 201, but MetalLB L2Advertisement only cares about subnet membership, not zone. | **Independent — can proceed in either order.** |
| **Audit P2 #12 (firewall groups)** | Pre-flight item — groups must exist before phase 1 to keep rule text clean. | Pre-flight item. |
| **L3 switch ACL audit (audit P3 #21)** | Phase 2/4 risk is harder to bound until we know what the switch is enforcing. | Should land before Phase 2. |
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
- [ ] **Out-of-band SSH path tested** — verified that I can reach `10.10.200.1` from outside the LAN (via AWS-WG path) and that a totally-broken zone rule wouldn't kill that path.
- [ ] **L3 switch ACL state captured** — UI screenshot or `show running-config` from the L3 switch documenting what cross-VLAN ACLs are currently enforced. Without this, Phase 2 risk is unbounded.
- [ ] **Firewall groups created in their own PR** (audit P2 #12) and verified rule-referencable in the UI.
- [ ] **All four phases scheduled with maintenance windows announced** to any household users who depend on the network (kids' WiFi, IP phones, alarm system, etc.).
- [ ] **Decision made on Default/199** (keep / quarantine / delete DHCP) — to be applied in Phase 5.
- [ ] **VPN zone decision made** — either delete `WireGuard WAN1` (M14) or keep with a documented `VPN → Internal` deny stance. Don't carry the "VPN → Internal: Allow All" default into the new model.
- [ ] **Decided whether to do Phase 4** at all — Phases 1-3 give most of the security benefit (untrusted networks isolated). Phase 4 (moving 200/201/202 out of Internal) is symbolic mostly, since they'd all be in one wide-open `Trusted` zone anyway. If the appetite for risk is low, **stopping after Phase 3** is a valid end state, with Trusted = Internal forever.
- [ ] **Reviewer alignment** — at least one second pair of eyes (or `claude` review pass) on the Phase 4 inter-zone allow list. Phase 4 is the only phase that can plausibly lock you out of every admin path simultaneously.

---

## 7. Open questions for the user

These are the things the audit couldn't resolve and that this planning doc doesn't decide unilaterally:

1. **Does SimpliSafe phone home via cells, WiFi, or both?** Determines whether `Security → External: Block` in Phase 3 is safe.
2. **Are there any backup/sync jobs from Clients/202 to Servers/201** that don't go through documented K8s services? If yes, enumerate before Phase 4.
3. **Decision on Default/199 (Phase 5):** keep, quarantine, or delete the DHCP scope?
4. **Does the WireGuard WAN1 VPN pool ever get re-enabled, or should it be deleted?** Affects whether the matrix needs a populated `VPN → *` row.
5. **L3-switch ACL surface area:** are we eventually going to manage these via Ansible (per `ubiquiti-config-as-code-2026-05-16.md` Phase 3), or accept that the L3 switch is hand-managed forever? Phase 2 risk is meaningfully different depending on this choice.

---

## 8. Out of scope

- eBGP between UDM and L3 switch (M18) — independent.
- L3 switch ACL codification — handled by `ubiquiti-config-as-code-2026-05-16.md` Phase 3 separately.
- Identity Enterprise / 802.1X — out per audit §2.7.
- mDNS reflector, IGMP snooping, hostname-based VPN routing — out per audit §2.5 and §2.9.
- Per-VLAN bandwidth caps on Guest — separate (audit P3 #23).
