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

### 4.1 Direct storage interface — NODE-level on VLAN 209 (corrected)

**DECISION (committed 2026-05-29):** proceed with the move-Servers/201-to-UDM-routed design.

**Mechanics correction:** the NAS workloads use **in-tree `nfs:` volumes** (`server: sequoia.wind.etherport.net` → `10.10.209.10`). In-tree NFS volumes are mounted by the **kubelet on the node**, so the NFS traffic originates from the **node's** network stack — NOT a pod Multus interface. Therefore the fast-path fix is a **node-level 209 interface**, exactly like the existing Ceph NIC (`enp6s22` on VLAN 210, MTU 9000, per-MAC IPs .50-.60). Pod-level Multus would NOT help in-tree NFS.

**NAS-touching workloads enumerated (all NFS → `sequoia` / 209.10):**

| Workload | NFS path | Throughput profile |
|---|---|---|
| **plex** (`plex` ns) | `/var/nfs/shared/Media/{Movies,TV Shows}` | **High, sustained** — playback + transcode source reads |
| **s3-sync** ×7 shares (`backups` ns) | `/var/nfs/shared/{archive,backups,content,graham,mark,media,scans}` | **High, bursty** — full NAS reads during sync windows |
| **rclone-gdrive** (`rclone-gdrive` ns) | `/var/nfs/shared/Backups` | Moderate — periodic |

All three mount at node level → all are degraded if node→209 routes through the UDM after the 201 move. → **all workers that can run these need a 209 node interface.**

**Implementation — pure SDN (cleaner than the Ceph NIC, which had to use a raw bridge):**

The `vsan` SDN VNet (tag 209) **already exists + is applied + healthy** on the PVE host (`infra/terraform/proxmox/sdn/vnets.tf`; verified `vsan` bridge UP, enslaving `vmbr0.209` as its uplink, no host IP → no conflict). So adding the 209 node interface is the clean SDN path:
- Attach a new vNIC to each K8s worker VM with `bridge=vsan` (the existing SDN VNet) — exactly like net0-3 use `servers`/`clients`/`iot`/`security`. No new VNet, no raw `vmbr0+tag`, no host-conflict risk.
- netplan/cloud-init: per-MAC fixed IPs in `10.10.209.5x`, MTU 9000.
- With a connected route to `10.10.209.0/24` on the node, kubelet NFS mounts to `sequoia` (209.10) egress the 209 NIC at L2 — bypassing the UDM even after 201 becomes UDM-routed.

> **Do NOT convert the Ceph 210 NIC to SDN.** It's deliberately the raw `vmbr0+tag=210` pattern because the PVE host carries its Ceph mon IP (`10.10.210.41`) directly on `vmbr0.210` — defining an SDN VNet for 210 would generate a conflicting `interfaces.d/sdn` stanza and `ifreload` would tear down the host (2026-05-18 incident, iKVM recovery). The net0-3 (SDN) vs net4 (raw 210) inconsistency is **intentional + correct**, documented in `vnets.tf`. VLAN 209 has no host IP, so it gets the proper SDN treatment.

This keeps Servers/201's *primary* interface low-bandwidth (UDM routing it = fine) while NAS-heavy node mounts get the fast switch-fabric side-channel.

### 4.2 BGP config (after 201 is UDM-routed)
- **ASNs:** private — MetalLB `64512`, UDM `64513` (eBGP). Confirm no clash with AWS/WG (regional VPN uses static routes today → free).
- **UDM:** Settings → Routing → BGP → upload an FRR config: local ASN 64513, neighbors = each K8s node's 201 IP (cp1-3 `.50-.52`, w1-4 `.53-.56`, gpu1 `.60`), accept the pool /32s.
- **MetalLB CRs:** replace `L2Advertisement` with `BGPPeer` (peer = UDM `10.10.201.1`, myASN 64512, peerASN 64513) + `BGPAdvertisement` (pool `primary`).
- **Pool stays `.201.x`** (no VIP re-IP). Note: pool is *inside* the node subnet — BGP /32s are more-specific than the connected /24, so they win; works but slightly unusual (a dedicated LB CIDR would be textbook — deferred to avoid DNS-`.5` churn).

> **Sequencing note:** the "move Servers/201 to UDM-routed" step is itself a careful change (it's the K8s nodes' primary VLAN). It should be its own mini-phase with verification (nodes still reach each other intra-201 = unaffected since that's L2; cross-VLAN + internet via UDM verified) BEFORE layering BGP on top. Consider doing it during the same window as adding the 209 storage interfaces so server↔storage never degrades.

---

## 5. Migration plan (staged, reversible) — peer with the UDM

Four mini-phases, each independently verifiable + reversible. Phases A→B are the prerequisite re-architecture; C→D are the BGP cutover.

**Phase A — add node 209 interfaces (no routing change yet):**
1. Add a vNIC `bridge=vsan` (existing SDN VNet, tag 209) to each K8s worker VM via `infra/terraform/proxmox/k8s-vms` + netplan per-MAC IPs `10.10.209.5x`, MTU 9000. (Pure SDN — NOT the raw vmbr0+tag the Ceph NIC uses; see §4.1.)
2. Verify each node has a connected route to `10.10.209.0/24` and can reach `sequoia` (209.10) over the 209 NIC.
3. Drain/cycle the NAS workloads (plex, s3-sync, rclone) so their kubelet NFS mounts re-establish over the 209 path. Confirm via `ss`/traffic that node→sequoia uses the 209 NIC. **No 201 routing change yet, so zero risk** — this just adds a faster path.

**Phase B — move Servers/201 to UDM-routed:**
> **IaC note (verified 2026-05-29):** the static L3 routes (AWS + WG) ARE codified in `infra/terraform/unifi/routes.tf` (6/6, zero drift). BUT the per-VLAN routing *assignment* (`gateway_type` switch↔default) is NOT modeled by the paultyng `unifi_network` provider — same gap class as zones/firewall/ACLs. So this Phase-B switch→UDM change is a **UI / v2-API + documented** change, not a `terraform apply`. Capture the before/after in the doc + verify routes.tf next-hops (10.255.253.3 / 10.10.201.20) still resolve after the move.
4. In UniFi: change VLAN 201 `gateway_type` switch → default (gateway `.1` moves from the switch SVI to the UDM SVI; same IP).
5. Verify: intra-201 node↔node still works (L2, unaffected); node→internet + node→other-UDM-VLAN routes via UDM; **node→sequoia still fast over the 209 NIC** (the whole point of Phase A); cluster health green (CNPG, Ceph, pods).
6. *(Bonus, optional)* move Servers/201 into a `Trusted` UDM firewall zone — now possible since it's UDM-routed.
   **Rollback:** revert `gateway_type` to switch.

**Phase C — BGP, parallel with L2 still primary:**
7. UDM: Settings → Routing → BGP → FRR config (ASN 64513, neighbors = node 201 IPs, accept pool /32s).
8. Add `BGPPeer` + `BGPAdvertisement` CRs **alongside** the existing `L2Advertisement` (MetalLB runs both — routes advertise while ARP still answers).
9. Verify the UDM learns the /32s (`stat/routing/bgp` populates) with node next-hops.

**Phase D — cut over + clean up:**
10. Remove `L2Advertisement`. Verify each VIP reachable cross-VLAN (DNS to `.5`, Traefik `.70`, syslog `.73`).
11. Confirm the IP-conflict alerts STOP (M36 resolved — no more ARP ownership).
12. Update `metallb/README.md` + `firewall-zones.md` to document BGP mode + the 201-UDM-routed topology.
    **Rollback:** re-add `L2Advertisement` (instant L2 revert); VIPs never change IP → non-disruptive.

**Risks:**
- **DNS VIP `.5`** is the cluster's primary resolver — botched Phase D briefly breaks DNS for anything pointing at `.5`. Mitigate: `.6` (dns-fallback VM) + AWS path remain; short window; low-use timing.
- **Phase B is the riskiest** (it re-homes the K8s nodes' primary-VLAN gateway). Phase A must be verified first so NAS throughput never gaps. Intra-201 (control plane) is L2 → unaffected by the gateway move.
- `externalTrafficPolicy` per LB service (Local vs Cluster) — Local keeps advertisement on the serving node + preserves client IP; set before Phase C for Traefik + Technitium.
- ASN coexistence with any AWS/WG BGP (regional VPN is static today → likely free; confirm).

---

## 6. Open questions
1. **US624P BGP support** (§3) — gating.
2. ASN selection + any AWS/WG BGP coexistence.
3. `externalTrafficPolicy` per LB service (esp. Traefik + Technitium) — Local keeps advertisement on the serving node + preserves client IP.
4. Does UniFi's switch BGP support ECMP / multipath for the /32s, or single best-path?

---

## 7. Effort
Medium. Gated on §3. If the switch supports BGP: ~1 maintenance window for the staged cutover + soak. If it doesn't, the re-IP fallback (§3.1) adds scope (re-point Technitium/Traefik/clients).
