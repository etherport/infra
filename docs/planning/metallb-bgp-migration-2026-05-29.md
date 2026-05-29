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

## 3. The gating question — does the US624P support BGP peering?

This determines the entire approach. The BGP peer must be the router **in the data path** for the LB subnet = the US624P (it routes VLAN 201).

- **If US624P supports BGP** (UniFi exposes it under the switch's routing config on Network 10): MetalLB speakers peer with the switch. Clean, in-path, done. ← preferred
- **If it does NOT** (BGP may be gateway-only on UniFi, or limited to Enterprise/Aggregation switch models): fallbacks, in rough order of preference:
  1. **Peer with the UDM + move the LB pool to a UDM-routed VLAN** (e.g., a dedicated `lb`/Management-adjacent VLAN). Then the UDM is in-path and learns the routes. Cost: re-IP the 5 VIPs + update Technitium/Traefik/clients referencing them.
  2. **Peer with the UDM but keep pool on 201** — only works if the switch has a static route to the UDM for the LB /32s or the UDM redistributes into the switch; messy, likely not viable.
  3. **Stay L2 + apply the M36 suppression workaround** (UDM Insights → IP Conflict Detection → exclude `.5`/`.71`). The fallback if BGP isn't cleanly available.

**ACTION (first step, before any design commitment):** verify US624P BGP support — UniFi UI → the switch → Settings/Routing for a BGP section, or Network → Settings → Routing → BGP and whether the switch can be selected as a BGP router. Confirm on Network 10.4.57.

---

## 4. Target design (assuming US624P supports BGP)

- **ASNs:** private 16-bit — e.g., MetalLB `64512`, US624P `64513` (eBGP). Confirm no clash with the AWS-side WG/BGP if any (regional VPN uses static routes today, so likely free).
- **MetalLB CRs:** replace `L2Advertisement` with:
  - `BGPPeer` → peer-address = the US624P's VLAN 201 SVI (`10.10.201.1`), myASN 64512, peerASN 64513
  - `BGPAdvertisement` → pool `primary` (optionally aggregation-length /32)
- **US624P:** add BGP config — local ASN 64513, neighbor = each K8s node's 201 IP (or a peer-group), accept the /32s.
- **Keep the pool addresses identical** (.5, .70-90) — no VIP changes, so nothing downstream (Technitium split-horizon, Traefik DNS, clients) needs updating. This is the big advantage of peering with the in-path switch.

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
