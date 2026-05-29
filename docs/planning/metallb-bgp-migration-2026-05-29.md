# MetalLB L2 → BGP migration (design)

**Date:** 2026-05-29
**Status:** Design. No MetalLB/switch changes made yet.
**Tracker:** **M18** (eBGP/MetalLB BGP) + **M36** (IP-conflict alerts) in `docs/planning/outstanding-work.md`.
**Goal:** replace MetalLB L2 mode with BGP so LoadBalancer VIPs are advertised as /32 routes instead of claimed via gratuitous ARP — which permanently fixes the recurring UDM IP-conflict alerts (M36) without the suppression workaround.

---

## 1. Why

MetalLB **L2 mode** elects ONE speaker pod per VIP to answer ARP. When that speaker moves (pod restart, node drain, controller re-election) the VIP's MAC changes, and the UniFi fabric sees the same IP claimed by multiple MACs over time → **IP-conflict alerts** for `10.10.201.5` + `.71` (M36). It works correctly; it just looks like a conflict.

**BGP mode** has each speaker advertise the VIP as a **/32 route** to a BGP peer. No ARP claim, no MAC ownership, no conflict — the router just has an ECMP/next-hop route. This is the clean fix.

---

## 2. Current state (captured 2026-05-29)

**MetalLB:** L2 mode. `platform/kubernetes/metallb/metallb-wind.yaml`:
- `IPAddressPool/primary`: `10.10.201.5/32` + `10.10.201.70-10.10.201.90`, autoAssign
- `L2Advertisement/primary` → pool `primary`

**Live LoadBalancer VIPs (all on VLAN 201 / Servers):**

| Service | VIP |
|---|---|
| dns/technitium (aggregator) | 10.10.201.5 |
| dns/technitium-0 | 10.10.201.71 |
| dns/technitium-1 | 10.10.201.72 |
| traefik/traefik | 10.10.201.70 |
| monitoring/alloy-syslog | 10.10.201.73 |

**Routing reality (the crux):** VLAN 201 is **switch-routed by Switch Rack PoE (US624P @ 10.10.200.232)** — `gateway_type=switch` (see `docs/architecture/firewall-zones.md`). Inter-VLAN traffic to a `.201.x` VIP (e.g., a client on 202 → Traefik `.201.70`) is routed by the **switch**, never the UDM. So the router that must learn the BGP /32 routes is the **US624P switch**, not the UDM.

**Versions:** UDM Network app `10.4.57` (eBGP-capable). US624P firmware `7.5.2.16967`.

---

## 3. RESOLVED 2026-05-29 — UniFi switches don't do BGP; BGP is gateway-only

Confirmed via API + UI:
- `stat/routing/bgp` exists on the **UDM** (returns empty = BGP-capable, unconfigured). BGP on UniFi is a **gateway feature**, configured via an FRR config on the UDM (Network 8+).
- The US624P does **static routes only** (`/rest/routing` = all `static-route`; no dynamic protocol). No UniFi switch — including Pro Max — is a BGP speaker.
- UI confirmation: the BGP config (which runs on the UDM) shows **no switch-routed networks** as eligible interfaces, because the UDM doesn't route them.

**Therefore the original plan (peer MetalLB ↔ switch) is impossible.** For UDM-peered BGP to work, the LB pool's VLAN must be **UDM-routed**. That forces a routing-topology decision (§4).

The three viable paths:
1. **Move Servers/201 to UDM-routed** (recommended — see §4). LB pool stays at `.201.x` (no VIP re-IP); UDM becomes the 201 gateway + BGP peer. Throughput-sensitive server↔storage flows handled by direct storage-VLAN interfaces (§4.1).
2. **Dedicated UDM-routed `lb` VLAN**, move only the 5 VIPs there. Servers/201 stays switch-routed. More surgical, but re-IPs the VIPs — DNS `.5` is referenced in DHCP/split-horizon/clients → real churn.
3. **Stay L2 + M36 suppression workaround** (UDM Insights → IP Conflict Detection → exclude `.5`/`.71`). No BGP; just silences the cosmetic alerts. The do-nothing-structural fallback.

---

## 4. Recommended design — move Servers/201 to UDM-routed + direct storage interfaces

This is the production-standard hybrid (and answers the "should Servers be UDM-routed?" question). Rationale:

**Route the low-bandwidth / policy-sensitive VLAN through the gateway; keep high-throughput east-west on the switch fabric; multi-home the throughput-sensitive hosts directly onto the storage VLAN.** This is exactly how the cluster already does Ceph (K8s nodes have a dedicated `enp6s22` on VLAN 210) — we extend the same pattern.

**Routing changes:**
- **Servers/201 → UDM-routed** (`gateway_type` switch → default; the `.1` gateway moves from the switch SVI to the UDM SVI — same IP, K8s nodes need no reconfig). Unlocks: (a) UDM BGP-peering for the MetalLB pool → fixes M36; (b) Servers/201 can finally join a UDM firewall zone (it's currently zoneless); (c) consolidates LB-VIP + server north-south routing under UDM policy.
- **Clients/202, vSAN/209, Ceph/210 stay switch-routed** — preserves line-rate client↔NAS (the video-editing flow) + storage east-west.

**Throughput validation** (why this is safe):

| Flow | Path after change | Verdict |
|---|---|---|
| Server ↔ Client (201↔202) | via UDM | low-bw (kubectl, web UI, SSH) — fine |
| Server → Internet (201→WAN) | via UDM | unchanged (UDM is WAN gw anyway) |
| **Server → storage (201→209/210)** | **direct Multus iface on storage VLAN, L2** | **line-rate, bypasses UDM** ← key |
| Client ↔ NAS (202↔209) | switch (both switch-routed) | line-rate, unchanged |
| K8s ↔ Ceph (210) | intra-VLAN-210 L2 | unchanged |
| Any → LB VIP (`.201.x`) | via UDM | VIPs are all low-bw (DNS/web/syslog) — fine |

### 4.1 Direct storage interfaces (the s3-sync case)
Throughput-sensitive server services get a **Multus macvlan interface on VLAN 209** (NAS) — same pattern as the Ceph workloads on 210 — so they read/write storage at L2 without routing through the UDM:
- **s3-sync** (`backups` ns): reads NAS over a `.209.x` iface, uploads to AWS S3 over WAN (the S3 leg is internet-bound anyway, so UDM routing there is irrelevant). The high-throughput NAS-read leg stays on the switch fabric.
- Any future NAS-heavy workload: add a 209 NAD the same way.
- This keeps Servers/201's *primary* interface low-bandwidth (so UDM routing it is fine) while the storage-hungry pods get a fast side-channel.

### 4.2 BGP config (after 201 is UDM-routed)
- **ASNs:** private — MetalLB `64512`, UDM `64513` (eBGP). Confirm no clash with AWS/WG (regional VPN uses static routes today → free).
- **UDM:** Settings → Routing → BGP → upload an FRR config: local ASN 64513, neighbors = each K8s node's 201 IP (cp1-3 `.50-.52`, w1-4 `.53-.56`, gpu1 `.60`), accept the pool /32s.
- **MetalLB CRs:** replace `L2Advertisement` with `BGPPeer` (peer = UDM `10.10.201.1`, myASN 64512, peerASN 64513) + `BGPAdvertisement` (pool `primary`).
- **Pool stays `.201.x`** (no VIP re-IP). Note: pool is *inside* the node subnet — BGP /32s are more-specific than the connected /24, so they win; works but slightly unusual (a dedicated LB CIDR would be textbook — deferred to avoid DNS-`.5` churn).

> **Sequencing note:** the "move Servers/201 to UDM-routed" step is itself a careful change (it's the K8s nodes' primary VLAN). It should be its own mini-phase with verification (nodes still reach each other intra-201 = unaffected since that's L2; cross-VLAN + internet via UDM verified) BEFORE layering BGP on top. Consider doing it during the same window as adding the 209 storage interfaces so server↔storage never degrades.

---

## 5. Migration plan (staged, reversible)

Pre-flight:
- [ ] **Confirm US624P BGP support** (§3) — hard gate.
- [ ] UDM/switch config backup current (M31 covers the controller DB).
- [ ] Pick + record ASNs; confirm no conflict with AWS/WG routing.
- [ ] Identify the K8s node 201 IPs that will be BGP speakers (cp1-3 .50-.52, w1-4 .53-.56, gpu1 .60).

Phase 1 — **parallel BGP session, L2 still primary:**
1. Configure BGP on the US624P (neighbors = node IPs, ASN).
2. Add `BGPPeer` + `BGPAdvertisement` CRs **alongside** the existing `L2Advertisement` (MetalLB can run both; routes get advertised while ARP still answers).
3. Verify the switch learns the /32s (`show ip bgp` equiv in UniFi) and that they resolve to node next-hops.

Phase 2 — **cut over:**
4. Remove the `L2Advertisement` CR.
5. Verify each VIP still reachable from another VLAN (DNS query to `.5`, Traefik `.70`, syslog `.73`).
6. Watch for the IP-conflict alerts to STOP (they should cease once ARP ownership is gone).

Phase 3 — **clean up:**
7. Remove the M36 suppression workaround if it was ever applied.
8. Update `metallb/README.md` + `firewall-zones.md` to document BGP mode.

**Rollback:** re-add the `L2Advertisement` CR (instant revert to L2); remove BGP CRs + switch BGP config. VIPs never change IP, so rollback is non-disruptive.

**Risks:**
- DNS VIP `.5` is the cluster's primary resolver — a botched cutover briefly breaks DNS for everything pointing at `.5`. Mitigate: `.6` (dns-fallback VM) + the AWS path remain; keep the maintenance window short; cut over during low-use.
- ECMP: if multiple speakers advertise the same /32, the switch load-balances — fine for the stateless DNS/syslog VIPs, verify Traefik (stateful-ish) behaves (MetalLB BGP typically advertises from the node running the service via `externalTrafficPolicy: Local` to avoid this).
- Confirm `externalTrafficPolicy` per service (Local vs Cluster) — affects which nodes advertise + source-IP preservation.

---

## 6. Open questions
1. **US624P BGP support** (§3) — gating.
2. ASN selection + any AWS/WG BGP coexistence.
3. `externalTrafficPolicy` per LB service (esp. Traefik + Technitium) — Local keeps advertisement on the serving node + preserves client IP.
4. Does UniFi's switch BGP support ECMP / multipath for the /32s, or single best-path?

---

## 7. Effort
Medium. Gated on §3. If the switch supports BGP: ~1 maintenance window for the staged cutover + soak. If it doesn't, the re-IP fallback (§3.1) adds scope (re-point Technitium/Traefik/clients).
