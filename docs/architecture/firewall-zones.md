# Firewall Zones and Policy

This document describes the **live** zone-based firewall configuration on the UDM Pro ("Windroute"), baseline sourced from the read-only audit at `docs/planning/archive/udm-audit-2026-05-23.md` (Part 1), updated 2026-05-28 to reflect the M30 zone-migration **Phase 1** (VLAN 212 → Infrastructure).

> **Controller version:** UniFi Network 9.4.x on UniFi OS 5.1.12. The v10 Zone-Based Firewall migration (`ZONE_BASED_FIREWALL`) completed 2024-12-22; the legacy `rest/firewallrule` endpoint is empty.

---

## Migration status (M30) — COMPLETE 2026-05-29

The zone migration is done. Final state: **three custom UDM zones** (IoT, Infrastructure, Security) for the UDM-routed VLANs, plus **L3-switch ACLs** (M52) for the switch-routed fabric. Phase history (planning detail archived at `docs/planning/archive/firewall-zones-future-state-2026-05-29-completed.md`):

- **Phase 1 ✅:** Custom `Infrastructure` zone — VLAN 212 (Unifi / Protect+Talk+Access fleet) moved in.
- **Phase 2 → M52 ✅:** vSAN/209 + Ceph/210 are L3-switch-routed (can't be UDM-zoned). East-west security is enforced by **switch ACLs** on Switch Rack PoE — applied + verified (see "L3-switch ACLs" section below).
- **Phase 3 ✅:** Custom `Security` zone — VLAN 205 (SimpliSafe) moved in; legacy network-isolation toggle retired so the zone model is the single source of truth.
- **Phase 4 — SUPERSEDED by M56 (2026-05-31).** This was skipped on the premise that Servers/201 was switch-routed and couldn't be UDM-zoned. The **MetalLB BGP migration (M18/M36)** then made 201 **UDM-routed** (its default gateway is the UDM `10.10.201.1` — verified live: every inter-VLAN flow from a 201 host first-hops the UDM), so it *can* now be zoned — and the networking review judged the segmentation worth it. See "M56 — Trusted / Management zones" below.
- **Phase 5 ✅:** this doc reconciled to the live state; planning companion archived.

**Why the hybrid split:** the UDM is CPU-bound (~3.5-5 Gbps); Switch Rack PoE has a ~50 Gbps line-rate fabric. Storage (vSAN/Ceph at 10G + jumbo) and workstation→NAS flows MUST stay switch-routed for performance, so their security lives in switch ACLs, not UDM zones. Textbook firewall-north-south / L3-switch-east-west architecture.

**Historical note:** earlier revisions described a 6-custom-zone design that was never implemented — only `IoT` existed pre-migration. Tracker: **M30** in `docs/planning/outstanding-work.md`.

## M56 — Trusted / Management zones (2026-05-31)

Enabled by the BGP migration making Servers/201 UDM-routed. Two new custom zones split the former "everything trusted lives in `Internal`" lump:

| Zone | Networks | Posture |
|---|---|---|
| **Trusted** | Servers/201 | Trusted workload tier. Broad egress (External, Gateway, Vpn, Internal, Infrastructure, Management) + ingress for the service paths it fronts. Behaviour-neutral vs the old `Internal` so the move didn't change workload connectivity. |
| **Management** | Management/200 | **Contained** management plane. May reach only External, Gateway, and `Trusted` (DNS to `.5/.6` + syslog to Alloy `.73`). Ingress from `Trusted` (the cluster administers the UDM/devices — poller, gh-runner, backup, cert-sync), `Vpn` (remote admin), `Gateway`. Default-denied to IoT / Guest / Security. |
| **Internal** | Default/199 | Now just the Default network; stays permissive. (Talk listens on `10.10.199.1` here, but the external Twilio port-forwards now target the asterisk-sbc on `10.10.201.40`, not `.199.1` — see Port Forwards.) |

Rules are codified in `infra/ansible/playbooks/udm-firewall.yml` (`udm_firewall_policies`, v2 API) — 20 zone policies + supporting address/port groups. **Why separate Management:** production practice isolates the device/admin plane so a compromised workload (or device) can't pivot freely; the cost is a few explicit `Trusted↔Management` allows for the cluster's infra tooling.

**Exception — trusted admin clients → Management (2026-06-10).** The always-on Mac mini ops host (`10.10.202.101`) sits on **Clients/202** (switch-routed, zoneless → it enters the UDM via the Internal transit, so it's matched with `zone_name: Internal` + an IP-group, same pattern as the syslog rule). Clients/202 has no path into the contained Management zone by default, so headless terraform-proxmox (mini → PVE `10.10.200.41:8006`) was dropped. The `trusted-admin-clients → Management (all)` policy (group = mini + admin laptop) opens it. Risk-equivalent to the existing `Vpn → Management` allow used for remote admin; scoped to named hosts, not all of Clients/202. The UDM/Gateway itself is already reachable from Clients (which is why the UDM web UI works from the mini). **Narrowed (H34, 2026-06-11):** the rule is now `protocol: tcp` to `mgmt-admin-hosts` (PVE `10.10.200.41`) on `Mgmt-Admin-Ports` (22/443/8006) with `logging: true` — not all-ports-to-the-whole-zone. The mini self-applies this playbook (UDM API reachable as Gateway; creds from SOPS `udm_tfadmin_*`). NB the policy reconcile is create-only, so narrowing meant creating the new rule + deleting the old broad one via the API.

**Gotcha — custom zones default intra-zone to BLOCK.** The built-in `Internal` zone has a predefined `Internal→Internal Allow All`; **custom zones do not** — a fresh custom zone's `Zone→same-Zone` policy is `Block All`. This bites `Trusted` via **hairpin routes**: the cluster reaches the AWS subnets (`10.10.100.0/22` etc.) over a UDM static route whose next-hop `10.10.201.20` is *back inside* 201, so the UDM evaluates that flow as `Trusted→Trusted` and drops it. Symptom when missing: `dns-aws`/`vpn-aws` `TargetDown` right after the zone move while everything else looks fine. Fix = the explicit `Trusted → Trusted (intra-zone)` allow in `udm-firewall.yml`.

**VPN — important clarification.** The `Vpn` zone contains **only the UDM's built-in backup WireGuard tunnel** (`WireGuard WAN1`). The **primary** k8s + `vpn-local` WireGuard runs on **Servers/201** behind the Keepalived VIP `10.10.201.20` (now in `Trusted`): its inbound is the `External → Trusted (WireGuard) udp/9820-9821 → .20` policy, and connected-client traffic is intra-`Trusted`. So the primary VPN does **not** depend on the `Vpn` zone; the `Vpn→Trusted/Management` allows exist to keep the *backup* UDM tunnel reaching servers/mgmt.

---

## Network Architecture Overview

The homelab network uses a **dual-router architecture** with routing responsibilities split between the UDM Pro and an L3 switch.

### Dual-Router Architecture

```
                              ┌──────────────────────────────────────────────────────────────┐
                              │                     INTERNET (WAN)                            │
                              └──────────────────────────────────────────────────────────────┘
                                                          │
                                                          ▼
┌─────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                         UDM Pro ("Windroute")                                            │
│                                    Primary Router / Firewall / NAT                                       │
│                                                                                                          │
│   Routes: Default (untagged), Management (200), Servers (201), IoT (204), Security (205),               │
│           Guest (206), Unifi (212), Inter-VLAN (4040)                                                    │
└─────────────────────────────────────────────────────────────────────────────────────────────────────────┘
       │           │           │           │           │           │           │
       ▼           ▼           ▼           ▼           ▼           ▼           ▼
 ┌──────────┐┌──────────┐┌──────────┐┌──────────┐┌──────────┐┌──────────┐┌──────────┐
 │ Untagged ││ VLAN 200 ││ VLAN 204 ││ VLAN 205 ││ VLAN 206 ││ VLAN 212 ││ VLAN 4040│
 │ Default  ││Management││   IoT    ││ Security ││  Guest   ││  Unifi   ││ Transit  │
 │ Internal ││Mgmt  (★) ││ IoT (★)  ││ Sec (★)  ││ Hotspot  ││Infra (★) ││ Internal │
 │10.10.199 ││10.10.200 ││10.10.204 ││10.10.205 ││10.10.206 ││10.10.212 ││10.255.253│
 └──────────┘└──────────┘└──────────┘└──────────┘└──────────┘└──────────┘└────┬─────┘
                                                                              │
                                         Inter-VLAN Transit (VLAN 4040)       │
                                         UDM: 10.255.253.1 ◄─────────────────►│
                                         L3 Switch: 10.255.253.3              │
                                                                              │
                ┌─────────────────────────────────────────────────────────────┘
                │
                ▼
 ┌────────────────────────────────────────────────────────────────────────────────────────┐
 │                           L3 Switch ("Switch Rack PoE")                                 │
 │                              Secondary Router                                           │
 │                                                                                         │
 │   Gateways ONLY for: Clients (202), vSAN (209), Ceph (210)                              │
 │   (Servers/201 is NOT switch-routed — its gateway is the UDM `10.10.201.1` since the     │
 │    M56/BGP migration, so 201 hangs under the UDM box above, not here. The switch is the  │
 │    SOLE enforcement point only for 202↔209↔210 east-west, which never touches the UDM.)  │
 │   Static routes to AWS (10.10.100.0/22, 10.255.255.0/29, 10.254.0.0/24)                │
 └────────────────────────────────────────────────────────────────────────────────────────┘
                                 │              │             │
                                 ▼              ▼             ▼
                           ┌──────────┐   ┌──────────┐  ┌──────────┐
                           │ VLAN 202 │   │ VLAN 209 │  │ VLAN 210 │
                           │ Clients  │   │   vSAN   │  │   Ceph   │
                           │ Internal │   │ Internal │  │ Internal │
                           │10.10.202 │   │10.10.209 │  │10.10.210 │
                           └──────────┘   └──────────┘  └──────────┘
  (Servers/201 — Trusted — is UDM-routed; it is a child of the UDM box above, not the switch.)

  (★) There are FIVE custom zones on the controller: Trusted (Servers/201),
      Management (200), IoT (204), Infrastructure (Unifi/212), Security (205)
      (M30 migration 2026-05-28/29; Trusted/Management added by M56 2026-05-31).
      "Internal" now holds only the Default network. Servers/201 is fully
      UDM-routed (Trusted zone) since the BGP migration — ALL its inter-VLAN
      traffic transits the UDM. The switch-routed VLANs (202/209/210) and the
      4040 transit are in no UDM zone; switch ACLs are the sole enforcement only
      for 202↔209↔210 east-west (the flows that never reach the UDM).
```

### Firewall Implications of Dual-Router Architecture

The UDM firewall only sees traffic that traverses the UDM. Since the BGP migration (M56) Servers/201 is **UDM-routed/zoned (Trusted)**, so routed 201↔202 flows now **transit the UDM** (matched by the `Trusted` zone policies). The only paths that truly **bypass** the UDM are L2/intra-VLAN: K8s↔Ceph stays **intra-VLAN-210 (L2)**, and the direct node↔NAS storage path runs on the vSAN/209 NIC — neither crosses an L3 boundary.

| Traffic Path | Firewall Applies? | Example |
|--------------|-------------------|---------|
| Servers (201) ↔ Clients (202) | **Yes** — routed via UDM (Trusted zone) | Laptop → K8s service |
| Servers (201) → vSAN (209) | **No** — direct node↔NAS NIC, L2 storage path | Proxmox → vSAN storage |
| K8s nodes ↔ Ceph (210) | **No** — intra-VLAN-210 (L2) | K8s nodes ↔ Ceph mons |
| Servers (201) ↔ IoT (204) | **Yes** — crosses UDM | Server → Home Assistant |
| Clients (202) ↔ Internet | **Yes** — crosses UDM | Web browsing |
| IoT (204) ↔ Security (205) | **Yes** — crosses UDM (and blocked, see below) | (not allowed) |
| Any ↔ Internet | **Yes** — crosses UDM | All internet traffic |

**Where to apply security policies:**

| Traffic Flow | Where to Configure |
|--------------|-------------------|
| Servers/201 north-south (to/from any other VLAN or Internet) | **UDM Zone-Based Firewall** (`Trusted` zone, since M56) |
| Between switch-routed VLANs (202, 209, 210) | **L3 switch ACLs** (deployed via `infra/ansible/playbooks/usw-acls.yml`, M52 — see below) |
| Between UDM-routed VLANs (200, 201, 204, 205, 206, 212, 4040) and itself | UDM Zone-Based Firewall |
| Between switch-routed and UDM-routed VLANs | UDM Zone-Based Firewall (traffic transits VLAN 4040) |
| To/from Internet | UDM Zone-Based Firewall |

### L3-switch ACLs (M52 — deployed 2026-05-29)

The switch-routed fabric (Clients/202, vSAN/209, Ceph/210 — these three are gatewayed by the L3 switch) is policed by IP ACLs on **Switch Rack PoE** (US624P @ `10.10.200.232`), managed declaratively by `infra/ansible/playbooks/usw-acls.yml` (`/proxy/network/v2/api/site/default/acl-rules`). Switch default is allow-all, so these are explicit BLOCK overrides + one preserved ALLOW. **⚠️ Drift note (M56):** the playbook's header + the captured baseline predate M56 (2026-05-31) and still list **Servers/201 as switch-routed** — that is now FALSE (201's gateway is the UDM). Consequence: any ACL row with **201 as src/dst is dead or redundant** — a 205→201 or 201→x flow is routed by the UDM, so it's policed by the UDM `Trusted`/`Security` zones, NOT the switch (for 205→201, both ends are UDM-routed so the packet never reaches the switch at all). The switch ACLs are the SOLE enforcement only for **202↔209↔210**. These rows are harmless (the UDM enforces the real boundary) but should be pruned in a deliberate switch-ACL review — see the systemic-drift follow-up. Live rows:

| # | Action | Flow | Purpose |
|---|--------|------|---------|
| 0 | ALLOW | Hue bridges (`204.51/52`) → Clients/202 | Return path for Clients→Hue control |
| 1 | BLOCK | Security/205 → 201, 202, 209, 210 | Switch-side complement to the Security UDM zone for the switch-routed dests **202/209/210**. ⚠️ The **→201 entry is DEAD** post-M56 (205 & 201 are both UDM-routed → the flow never traverses the switch; the UDM Security zone blocks it). Prune in the switch-ACL review. |
| 2 | BLOCK | Ceph/210 → vSAN/209 | Separate storage backends, no cross-talk |
| 3 | BLOCK | Clients/202 → Ceph/210 | No client workflow needs raw Ceph |
| 4 | BLOCK | vSAN/209 → Ceph/210 | Separate storage backends |

**Deliberately NOT blocked** (allow-all default preserves them): Servers↔Clients, Servers→vSAN/Ceph (K8s RBD + CNPG), Clients→vSAN (10G NAS/video editing). K8s↔Ceph runs **intra-VLAN-210 (L2)** and never hits an ACL. Design + rollout detail: `docs/planning/archive/l3-switch-acl-iac-2026-05-28.md`.

---

## Complete VLAN Inventory

### Networks Routed by UDM Pro

| VLAN | Name | Subnet | Live Zone | Purpose |
|------|------|--------|-----------|---------|
| (untagged) | Default | 10.10.199.0/24 | Internal | Untagged native — should be empty, but DHCP `.100-.254` is still on. Talk service listens on `10.10.199.1` (see `unifi-talk.md`). |
| 200 | Management | 10.10.200.0/24 | **Management (custom)** | Network equipment (UDM, switches, APs). Contained admin plane (M56). |
| 201 | Servers | 10.10.201.0/24 | **Trusted (custom)** | K8s nodes, DNS (MetalLB `.5/.6`), infra services. **UDM-routed** (gateway = UDM `10.10.201.1`) since the M56/BGP migration — verified live (every inter-VLAN flow from a 201 host first-hops the UDM). ALL its inter-VLAN traffic transits the UDM and is policed by the `Trusted` zone; the 201↔202/209/210 path crosses the switch only as 202/209/210's gateway on the far side. |
| 204 | IoT | 10.10.204.0/24 | **IoT (custom)** | Smart home devices |
| 205 | Security | 10.10.205.0/24 | Internal | SimpliSafe gear (cameras retired) — Network Isolation = **OFF** (disabled per M104; verified live `network_isolation_enabled=false` 2026-06-29). DHCP DNS still empty — remaining M104 step. See §"Known anomalies" #1. |
| 206 | Guest | 10.10.206.0/24 | Hotspot (built-in) | Guest WiFi |
| 212 | Unifi | 10.10.212.0/24 | **Infrastructure (custom)** | UniFi Protect cameras (~13), Talk phones (3 UVP-TOUCH), UniFi Access (UA-Gate, UA-Intercom), Protect controller `.10`. **Note: APs/switches are NOT here — they're on Management/200.** Moved to Infrastructure 2026-05-28 (M30 Phase 1). |
| 4040 | Inter-VLAN | 10.255.253.0/24 | Internal | Transit between UDM and L3 switch |

### Networks Routed by L3 Switch

(Gateway = L3 switch for hosts on these VLANs. Inter-VLAN traffic **between** them — 202↔209↔210 — never touches the UDM, so the switch ACLs are its sole enforcement. Servers/201 is **not** here — it moved to UDM-routed at M56, see the table above.)

| VLAN | Name | Subnet | Live Zone | Purpose |
|------|------|--------|-----------|---------|
| 202 | Clients | 10.10.202.0/24 | Internal | User laptops, phones |
| 209 | vSAN | 10.10.209.0/24 | Internal | Storage network (Proxmox/NAS) |
| 210 | Ceph | 10.10.210.0/24 | Internal | Dedicated Ceph storage (PVE mon `.41`, K8s nodes `.50-.60` via `enp6s22` MTU 9000). Migrated 2026-05-18 from VLAN 201. |

### Networks Not in the Architecture Tables but Present on the UDM

| Network | Live Zone | Notes |
|---------|-----------|-------|
| WireGuard WAN1 (192.168.3.0/24) | VPN | UDM-side remote-user-VPN pool, no clients connected. Tracked under M42 / future cleanup. |
| LTE WAN | External | Failover priority 4, never used. Tracked for retirement. |
| WAN1 / WAN2 | External | Frontier (primary), Spectrum (failover-only). |

### Static Routes (UDM-carried)

| Destination | Purpose | Next-hop |
|-------------|---------|----------|
| 10.10.100.0/22 | AWS Environment | 10.10.201.20 (vpn-local/keepalived VIP on Servers/201) |
| 10.255.255.0/30 | WireGuard tunnel endpoint (AWS) | same |
| 10.254.0.0/24 | WireGuard client tunnel | same |

Note: live `routing` (UDM API, verified 2026-06-29) carries each route **once**, all `gateway_type=default`, next-hop `10.10.201.20`, with `gateway_device` = **Windroute (the UDM Pro Max)** — not the L3 switch. There is **no** `gateway_type=switch` duplicate and no `10.255.253.3` next-hop; the earlier "exists twice / hands transit to the switch" note was the old dual-router framing and is removed.

---

## Live Zone Inventory

UniFi Network creates a fixed set of built-in zones; you can add custom zones on top. Source: `zone-matrix.json`.

| Zone | Type | Member networks | Notes |
|------|------|-----------------|-------|
| **Internal** | built-in | Default/199 | Default = `Allow All Traffic` within the zone. Now holds only the Default network (Management/200 moved to `Management`, Servers/201 to `Trusted` — M56). **Switch-routed VLANs (Clients/202, vSAN/209, Ceph/210) + the InterVLAN/4040 transit are NOT members of any UDM zone** — their east-west security (202↔209↔210) is enforced by switch ACLs (see below); traffic to/from a UDM-routed VLAN transits the UDM (via VLAN 4040) and is policed there. Servers/201 is **UDM-routed and zoned (`Trusted`)** — all its inter-VLAN traffic transits the UDM (it is no longer switch-routed). |
| **Trusted** | custom | Servers/201 | M56 (2026-05-31). Trusted workload tier; broad egress + ingress for fronted services. Behaviour-neutral vs the old `Internal`. |
| **Management** | custom | Management/200 | M56 (2026-05-31). Contained admin plane; reaches only External/Gateway/`Trusted` (DNS + syslog). |
| **IoT** | custom | IoT/204 | Default block to other zones; one explicit allow for DNS. |
| **Infrastructure** | custom | Unifi/212 | M30 Phase 1. Protect/Talk/Access appliance fleet. Rules: Internal↔Infrastructure Allow All (broad — tightening deferred to a Phase 1.5 pass); Infrastructure→Gateway + →External auto-created by UDM. |
| **Security** | custom | Security/205 | M30 Phase 3 (2026-05-29). SimpliSafe (wifi-primary + cell-backup). Default block to all other zones; →External + →Gateway allowed (internet monitoring + DHCP/DNS). No internal-DNS rule (resolves via gateway/public). Legacy `network_isolation_enabled` retired — zone model is sole enforcement. |
| **External** | built-in | WAN1, WAN2, LTE | Internet. Inbound blocked by default with named exceptions (Twilio + WireGuard). |
| **Gateway** | built-in | UDM itself | DHCP/DNS/management surface of the UDM. Allow-most by default. |
| **VPN** | built-in | WireGuard WAN1 (UDM remote-user-vpn) | Currently no clients connected. VPN → Internal = Allow All (broad — if/when this pool is ever populated, VPN clients have full LAN reach). |
| **Hotspot** | built-in | Guest/206 | UniFi's purpose-built captive-portal zone. |
| **DMZ** | built-in | (none) | Not used. |

---

## Live Default Policies (Zone-to-Zone)

Decoded from `firewall-policies.json` + `zone-matrix.json`. The bulk are predefined (auto-generated UniFi boilerplate for zone defaults); the **user-authored** policies are now codified in `infra/ansible/playbooks/udm-firewall.yml` (`udm_firewall_policies`) — **~20 zone policies** (the `Trusted`/`Management` zone allows from M56, the IoT/Hotspot/External/syslog rules, etc.) plus supporting address/port groups, not the "4 user rules" of the pre-M56 audit. (The exact predefined total grows with each custom zone the controller adds; regenerate `/tmp/unifi-state/` via `scripts/unifi/dump-state.sh` for a current count.)

### Default behaviour from each source zone

| Source → Dest | Live default | Notes |
|---|---|---|
| Internal → Internal | **Allow All Traffic** | Internal now holds only the Default network; the switch-routed VLANs (202/209/210/4040) enter the UDM via the Internal transit. Servers/201 (Trusted) and Management/200 are in their own custom zones with explicit policies (see "M56" above), not this default. |
| Internal → External | Allow All Traffic | Standard outbound internet. |
| Internal → IoT | **Block All Traffic** | Servers cannot initiate to IoT devices. Practical impact: Home Assistant cross-VLAN control of a Hue bridge does not work without an explicit allow (none exists). |
| Internal → Gateway | Allow All | LAN reaches UDM management surface. |
| Internal → VPN | Allow All | Inert today (no VPN clients). |
| Internal → Hotspot | Allow All | **Permissive** — Internal can reach guest devices. Low practical risk (ephemeral devices) but tighter than necessary. |
| Internal → DMZ | Allow All | Unused. |
| IoT → Internal | Block All + 1 explicit allow ("Allow IoT to DNS") | Correctly isolated. |
| IoT → External | Allow All | IoT devices reach cloud services / NTP / updates. |
| IoT → Gateway | Allow Return Traffic | Stateful return only. |
| External → Internal | Block All + 6 named exceptions (Twilio-SIP, Twilio-Media, Allow-Wireguard, plus 3 predefined SLAAC/RA-style allows) | Standard WAN posture. |
| External → Gateway | 13 predefined allows (DHCPv6/RA/SLAAC/RADIUS/hotspot redirect) + Twilio + WireGuard inbound | Dense column of UniFi-managed boilerplate. |
| Hotspot → Internal | Block All + Allow Public DNS + portal-auth exceptions | Standard guest posture. |
| Hotspot → External | Allow All (post-auth) | Guests reach internet. |
| VPN → Internal | Allow All | Untouched UniFi default. |

### Per-zone policy density

From `zone-matrix.json` (counts include predefined policies):

```
Internal → {Internal:2, External:3, Gateway:1, VPN:1, Hotspot:2, DMZ:2, IoT:3}
External → {Internal:6, External:3, Gateway:13, VPN:3, Hotspot:3, DMZ:3, IoT:3}
Gateway  → {Internal:1, External:1, all others:1}
VPN      → {Internal:1, External:1, all others:1}
Hotspot  → {Internal:4, External:3, …}
DMZ      → {all 1-3}
IoT      → {Internal:3, others:1}
```

---

## Explicit User-Authored Allow Rules

These four were the original non-predefined rules. **Live (2026-06-29) there are 28 user-authored (`predefined:false`) policies** — the M56 zone migration added ~24 zone allows (Trusted/Management/Infrastructure, IoT/Hotspot→Trusted DNS, External→Trusted WireGuard, Vpn admin, syslog, trusted-admin-clients→Management, etc.). The zone policies are codified in `infra/ansible/playbooks/udm-firewall.yml` (`udm_firewall_policies`, drift-checked daily by `ansible-drift-detection.yml`); a few legacy rules (the Twilio-6767 pair below) are **UI-only, not in the playbook**. Source for this snapshot: live `firewall-policies` + `firewall-groups`.

| Rule | Source | Destination | Protocol/Port | Purpose |
|------|--------|-------------|---------------|---------|
| **Allow IoT to DNS** | IoT zone (10.10.204.0/24) | `DNS-Servers` IP group (10.10.201.5, 10.10.201.6) | TCP/UDP `DNS-Ports` (53) | Lets IoT devices resolve via Technitium without exposing the rest of Servers. |
| **Allow-Wireguard** | External UDP, any source | 10.10.201.20 (keepalived VIP) | UDP 9821 (`WG-Ports-Inbound` group) | Inbound WireGuard for site-to-site (backs the `Wireguard Local` port-forward). |
| **Allow-Twilio-SIP-6767** ⚠️ LEGACY | External UDP, `Twilio Signal IPs` group | Gateway zone (UDM itself) | UDP 6767 | **VESTIGIAL** — the OLD direct Twilio→UDM-Talk path. The active Twilio path now terminates on the **asterisk-sbc (`10.10.201.40`, TCP 5061 + RTP)** via the port-forwards below; external Twilio no longer hits `:6767` on the UDM. Candidate for cleanup (like the dead 205→201 switch ACL). |
| **Allow-Twilio-Media-10000-60000** ⚠️ LEGACY | External UDP, `Twilio Media IPs` group | Gateway zone (UDM itself) | UDP 10000-60000 | **VESTIGIAL** — old UDM-Talk media range; superseded by the `Twilio-Media-Signal` port-forward (UDP 10000-20000 → `.40`). Candidate for cleanup. |

**Firewall groups in use** (source: `firewall-groups.json`):

| Group | Type | Used by |
|-------|------|---------|
| `DNS-Servers` | address-group (2 IPs) | Allow IoT to DNS |
| `DNS-Ports` | port-group (53) | Allow IoT to DNS |
| `Twilio Signal IPs` | address-group (8 /30s) | Allow-Twilio-SIP-6767 |
| `Twilio Media IPs` | address-group (1 /18) | Allow-Twilio-Media-10000-60000 |
| `WG-Ports-Inbound` | port-group (9821) | Allow-Wireguard |

That is the full inventory. The aspirational "Network Objects" table from the old doc (13 named groups) is not present today; expanding adoption is **P2 #12** in the audit.

---

## Port Forwards

Source: `port-forwards.json`.

| Rule | Direction | Port(s) | Target | Doc reference |
|------|-----------|---------|--------|---------------|
| `Twilio-SIP` | **TCP** inbound | **5061** | **10.10.201.40** (asterisk-sbc SIP bridge) | `infra/ansible/playbooks/asterisk-sbc.yml` |
| `Twilio-Media-Signal` | UDP inbound | **10000-20000** | **10.10.201.40** (asterisk-sbc media) | `infra/ansible/playbooks/asterisk-sbc.yml` |
| `Wireguard Local` | TCP+UDP inbound | 9821 | 10.10.201.20 (keepalived VIP) | `platform/wireguard/README.md` |
| `Wireguard Travel` | UDP inbound | 9820 | 10.10.201.20 | **Disabled** (`enabled=false`). Per session notes, travel VPN is now site→AWS; this rule should be deleted (P2 #9 in audit). |

---

## DNS Server Pointers (per-VLAN DHCP)

Source: `networks.json` (`dhcpd_dns_1`, `dhcpd_dns_2`).

| Network | DHCP DNS | Notes |
|---------|----------|-------|
| Default (199) | (none) | DHCP enabled but no DNS handed out — a smell, but no clients should be here anyway. |
| Management (200) | 10.10.201.5 / .6 | Technitium primary/secondary |
| Servers (201) | .5 / .6 | |
| Clients (202) | .5 / .6 | |
| IoT (204) | .5 / .6 | |
| **Security (205)** | **(explicitly empty)** | See "Known anomalies" below. |
| Guest (206) | 1.1.1.1 / 8.8.8.8 / 8.8.4.4 | Public resolvers — intentional, no leak to Technitium. |
| vSAN (209) | .5 / .6 | Harmless — vSAN nodes don't DNS. |
| Ceph (210) | .5 / .6 | |
| Unifi (212) | .5 / .6 | |

---

## Known anomalies (live state worth flagging, not yet fixed)

These are documented here so a reader doesn't mistake them for bugs in this doc. Each is tracked separately.

1. **Security/205 DHCP DNS empty (Network Isolation now OFF — M104 half-done).** Network Isolation was **disabled** per the M104 decision (verified live 2026-06-29: `network_isolation_enabled=false`), so the zone model is now the sole enforcement. **Remaining M104 step:** DHCP DNS is still empty (`dhcpd_dns_enabled=false`), so SimpliSafe gear still has no LAN resolver — set the DHCP Name Server to `10.10.201.5`/`10.10.201.6` (UI; the `unifi` TF provider lacks `network_isolation_enabled` and 205 isn't in TF). Tracked: **M104**.
2. **Internal → Hotspot is Allow All.** Anything on the Servers VLAN can reach guest devices. Practical risk: low (guests ephemeral). Documented intent was Deny. Tracked: audit P2 #11.
3. ~~**VPN zone is wired but unused.**~~ **RESOLVED 2026-06-24 (M42).** The `Vpn → Trusted/Management` allows were tightened from `all` → **TCP on `Vpn-Admin-Ports`** (22/53/80/443/6443/8006), logged, so a future break-glass WG client gets scoped admin access, not full LAN reach. The UDM backup WireGuard tunnel + `Vpn` zone are deliberately retained (break-glass for cluster/PVE VPN loss + future tunnels e.g. Teleport). (The built-in `VPN → Internal Allow-All` predefined policy can't be removed, but `Internal` no longer contains trusted server VLANs directly — those are reached via the scoped `Vpn → Trusted` rule.)
4. **LTE WAN still configured.** Failover priority 4, never carried traffic. Slated for removal.
5. **`Wireguard Travel` port-forward is `enabled=false`** but still in the config. Should be deleted (audit P2 #9).

---

## Unverified items (cannot confirm from controller API)

The controller's REST API does not expose these. Treat as unverified until checked via the UI or by SSHing the switch.

| Item | Why unverifiable | Disposition |
|------|------------------|-------------|
| L3 switch interface-to-VLAN bindings (which VLAN it routes vs. UDM) | Switch-local L3 config not in REST surface | Confirmed indirectly via `routing.json` next-hops — Servers/Clients/vSAN/Ceph route off the L3 switch. |
| L3 switch ACLs | ~~not in REST on 9.4.x~~ — **resolved**: they live at `v2/api/site/default/acl-rules` | **Now deployed + managed via IaC** (M52, `usw-acls.yml`). See "L3-switch ACLs" section above for the live rule set. Audit P3 #21 closed. |
| Switch port profiles (`Cameras / Phones / Clients / APs / UniFi Devices`) | — | All 5 confirmed present in `port-profiles.json`. |

---

## Configuring policies in UniFi Network 9.4.x

The v10 Zone-Based Firewall is **already migrated and enabled** (`ZONE_BASED_FIREWALL` migration ran 2024-12-22). Legacy `rest/firewallrule` returns 0 entries.

**Navigation:** `Settings` → `Security` → `Firewall` → Zone Matrix tab.

The matrix shows each (source, destination) zone pair as a cell; click into a cell to see/add policies for that flow. Built-in zones (Internal, External, Gateway, VPN, Hotspot, DMZ) cannot be deleted. The five custom zones (`Trusted`, `Management`, `IoT`, `Infrastructure`, `Security`) are managed under the same Firewall page.

If you are adding a new policy:

1. Open the matrix cell for the relevant (source, destination) pair.
2. Click **Create Policy**.
3. For source/destination, prefer **Network Objects** / **Port Groups** under `Settings > Profiles` over hard-coded IPs — keeps future renumbering cheap. Today only 3 IP groups and 2 port groups exist; expanding this catalogue is tracked under audit P2 #12.
4. Set `Connection State: All` unless you specifically need to scope to new/established.
5. Save and verify by watching `System Log` → `Triggers` for hits.

**Before disabling Network Isolation on any network**, check what relies on it. With Internal → Internal currently `Allow All`, no network now depends on L2 Network Isolation for its enforcement — Security/205's isolation was disabled per M104 (zone model is sole enforcement); see Known anomalies #1 for its one remaining step (DHCP DNS).

---

## Testing the current policy

These checks reflect the **live** behaviour, not the aspirational design.

### From an IoT device (10.10.204.x)

```bash
# Should work — explicit allow rule
nslookup google.com 10.10.201.5
dig @10.10.201.6 google.com

# Should work — IoT → External is Allow All
ping 8.8.8.8
curl -I https://google.com

# Should be blocked — IoT → Internal default is Block All (no allow exists)
ping 10.10.201.50      # K8s control plane
ping 10.10.205.10      # would-be NVR
ping 10.10.202.5       # Client laptop
```

### From a Servers/201 host (Trusted zone)

```bash
# Should work — Trusted → Gateway/External allowed; Trusted → Infrastructure (all)
ping 10.10.200.1       # Management gateway (Gateway zone surface)
ping 10.10.212.5       # Anything in Unifi/212 (Infrastructure) — Trusted → Infrastructure (all)

# Should FAIL — Trusted has no allow into IoT (204) or Security (205)
ping 10.10.204.51      # Hue bridge or similar
ping 10.10.205.10      # Anything in Security/205
```

Note: Servers/201 is the `Trusted` custom zone, Management/200 is the `Management` zone — neither is `Internal` any more (M56). The broad `Trusted → {External,Gateway,Vpn,Internal,Infrastructure,Management}` egress allows keep workload connectivity behaviour-neutral vs the old `Internal`.

### From a Guest device (10.10.206.x, Hotspot zone)

```bash
# Should work — Hotspot → External post-auth Allow
ping 8.8.8.8
curl -I https://google.com

# Should be blocked — Hotspot → Internal default Block
ping 10.10.201.5       # Internal DNS
ping 10.10.202.5       # Client
```

---

## Troubleshooting

### View firewall logs

`Settings` → `System` → `System Log` → `Triggers` tab. Filter by source IP.

### Common issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| IoT device can't resolve DNS | IoT zone allow-rule disabled, or device not in VLAN 204 | Check `Allow IoT to DNS` in matrix (`IoT → Internal`). Verify device DHCP DNS is `.5/.6`. |
| Server-side service can't reach Hue/IoT device | Internal → IoT is Block by default | Add an explicit allow in the `Internal → IoT` cell (none exists today). |
| Security/205 device can't resolve | DHCP DNS empty (Network Isolation now OFF) | See Known anomalies #1. Set DHCP Name Server to `.5`/`.6` (the remaining M104 step), or move .205 into a future custom zone with a DNS allow rule. |
| Can't reach UDM management | Gateway zone access blocked | Don't add deny rules to `Internal → Gateway`. |
| Traffic between Servers/Clients/vSAN/Ceph isn't filtered | Those VLANs route off the L3 switch — UDM never sees the traffic | Use L3 switch ACLs — now deployed via `usw-acls.yml` (M52). |
| Guest reaches internal device | Internal → Hotspot is currently Allow All | See Known anomalies #2. |

### Verify zone assignment

`Settings` → `Networks` → click the network → check **Zone** field. The five custom-zoned networks: Servers/201 (`Trusted`), Management/200 (`Management`), IoT/204 (`IoT`), Unifi/212 (`Infrastructure`), Security/205 (`Security`). Default/199 shows `Internal`, Guest/206 shows `Hotspot`; the switch-routed VLANs (202/209/210/4040) show no UDM zone.

---

## References

- `docs/planning/archive/udm-audit-2026-05-23.md` — read-only audit that drives this doc (Part 1)
- `docs/planning/archive/firewall-zones-future-state-2026-05-29-completed.md` — the proposed multi-zone migration (now ✅ implemented + archived; **this** doc is the live state)
- `docs/planning/outstanding-work.md` — M30 (reconcile zone arch), M42 (VPN cleanup)
- `/tmp/unifi-state/` — live state dump from `scripts/unifi/dump-state.sh` (regenerate to refresh)

> **ID note (M14 → M42):** the VPN/WireGuard cleanup referenced in this doc is tracked
> as **M42**. Pre-2026-05-16 archives (and any stale cross-references) called it **M14**;
> that ID was later reused for an unrelated `aws-s3-sync` SSL-probe item, so the WireGuard
> cleanup was renumbered to **M42** to disambiguate. Notes citing "M14" for VPN cleanup mean M42.
- [UniFi Zone-Based Firewalls — Ubiquiti Help Center](https://help.ui.com/hc/en-us/articles/115003173168-Zone-Based-Firewalls-in-UniFi)
- [Migrating to Zone-Based Firewalls](https://help.ui.com/hc/en-us/articles/28223082254743-Migrating-to-Zone-Based-Firewalls-in-UniFi)
