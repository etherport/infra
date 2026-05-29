# Firewall Zones and Policy

This document describes the **live** zone-based firewall configuration on the UDM Pro ("Windroute"), baseline sourced from the read-only audit at `docs/planning/udm-audit-2026-05-23.md` (Part 1), updated 2026-05-28 to reflect the M30 zone-migration **Phase 1** (VLAN 212 → Infrastructure).

> **Controller version:** UniFi Network 9.4.x on UniFi OS 5.1.12. The v10 Zone-Based Firewall migration (`ZONE_BASED_FIREWALL`) completed 2024-12-22; the legacy `rest/firewallrule` endpoint is empty.

---

## Migration status (M30) — COMPLETE 2026-05-29

The zone migration is done. Final state: **three custom UDM zones** (IoT, Infrastructure, Security) for the UDM-routed VLANs, plus **L3-switch ACLs** (M52) for the switch-routed fabric. Phase history (planning detail archived at `docs/planning/archive/firewall-zones-future-state-2026-05-29-completed.md`):

- **Phase 1 ✅:** Custom `Infrastructure` zone — VLAN 212 (Unifi / Protect+Talk+Access fleet) moved in.
- **Phase 2 → M52 ✅:** vSAN/209 + Ceph/210 are L3-switch-routed (can't be UDM-zoned). East-west security is enforced by **switch ACLs** on Switch Rack PoE — applied + verified (see "L3-switch ACLs" section below).
- **Phase 3 ✅:** Custom `Security` zone — VLAN 205 (SimpliSafe) moved in; legacy network-isolation toggle retired so the zone model is the single source of truth.
- **Phase 4 — SKIPPED (deliberate):** Servers/201 + Clients/202 are switch-routed (can't be UDM-zoned); the only UDM-routed candidate was Mgmt/200, and leaving it in Internal is functionally identical to a cosmetic `Trusted` zone. No security gain.
- **Phase 5 ✅:** this doc reconciled to the live state; planning companion archived.

**Why the hybrid split:** the UDM is CPU-bound (~3.5-5 Gbps); Switch Rack PoE has a ~50 Gbps line-rate fabric. Storage (vSAN/Ceph at 10G + jumbo) and workstation→NAS flows MUST stay switch-routed for performance, so their security lives in switch ACLs, not UDM zones. Textbook firewall-north-south / L3-switch-east-west architecture.

**Historical note:** earlier revisions described a 6-custom-zone design that was never implemented — only `IoT` existed pre-migration. Tracker: **M30** in `docs/planning/outstanding-work.md`.

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
│   Routes: Default (untagged), Management (200), IoT (204), Security (205), Guest (206),                 │
│           Unifi (212), Inter-VLAN (4040)                                                                 │
└─────────────────────────────────────────────────────────────────────────────────────────────────────────┘
       │           │           │           │           │           │           │
       ▼           ▼           ▼           ▼           ▼           ▼           ▼
 ┌──────────┐┌──────────┐┌──────────┐┌──────────┐┌──────────┐┌──────────┐┌──────────┐
 │ Untagged ││ VLAN 200 ││ VLAN 204 ││ VLAN 205 ││ VLAN 206 ││ VLAN 212 ││ VLAN 4040│
 │ Default  ││Management││   IoT    ││ Security ││  Guest   ││  Unifi   ││ Transit  │
 │ Internal ││ Internal ││ IoT (★)  ││ Sec (★)  ││ Hotspot  ││Infra (★) ││ Internal │
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
 │   Routes: Servers (201), Clients (202), vSAN (209), Ceph (210)                         │
 │   Static routes to AWS (10.10.100.0/22, 10.255.255.0/29, 10.254.0.0/24)                │
 └────────────────────────────────────────────────────────────────────────────────────────┘
                │              │              │             │
                ▼              ▼              ▼             ▼
          ┌──────────┐   ┌──────────┐   ┌──────────┐  ┌──────────┐
          │ VLAN 201 │   │ VLAN 202 │   │ VLAN 209 │  │ VLAN 210 │
          │ Servers  │   │ Clients  │   │   vSAN   │  │   Ceph   │
          │ Internal │   │ Internal │   │ Internal │  │ Internal │
          │10.10.201 │   │10.10.202 │   │10.10.209 │  │10.10.210 │
          └──────────┘   └──────────┘   └──────────┘  └──────────┘

  (★) IoT, Infrastructure (Unifi/212) and Security (205) are the three
      custom zones on the controller (M30 migration, 2026-05-28/29).
      "Internal" now holds only Default + Management/200. The switch-
      routed VLANs (201/202/209/210/4040) are in no UDM zone — their
      east-west security is enforced by L3-switch ACLs (see below).
```

### Firewall Implications of Dual-Router Architecture

The UDM firewall only sees traffic that traverses the UDM. Traffic between L3-switch-routed VLANs (201 ↔ 202 ↔ 209 ↔ 210) **never passes through the UDM** and is unaffected by anything in this document.

| Traffic Path | Firewall Applies? | Example |
|--------------|-------------------|---------|
| Servers (201) ↔ Clients (202) | **No** — L3 switch only | Laptop → K8s service |
| Servers (201) ↔ vSAN (209) | **No** — L3 switch only | Proxmox → vSAN storage |
| Servers (201) ↔ Ceph (210) | **No** — L3 switch only | K8s nodes ↔ Ceph mons |
| Servers (201) ↔ IoT (204) | **Yes** — crosses UDM | Server → Home Assistant |
| Clients (202) ↔ Internet | **Yes** — crosses UDM | Web browsing |
| IoT (204) ↔ Security (205) | **Yes** — crosses UDM (and blocked, see below) | (not allowed) |
| Any ↔ Internet | **Yes** — crosses UDM | All internet traffic |

**Where to apply security policies:**

| Traffic Flow | Where to Configure |
|--------------|-------------------|
| Between L3-switch VLANs (201, 202, 209, 210) | **L3 switch ACLs** (deployed via `infra/ansible/playbooks/usw-acls.yml`, M52 — see below) |
| Between UDM-routed VLANs (200, 204, 205, 206, 212, 4040) and itself | UDM Zone-Based Firewall |
| Between L3-switch and UDM-routed VLANs | UDM Zone-Based Firewall (traffic transits VLAN 4040) |
| To/from Internet | UDM Zone-Based Firewall |

### L3-switch ACLs (M52 — deployed 2026-05-29)

The switch-routed fabric (Servers/201, Clients/202, vSAN/209, Ceph/210) is policed by IP ACLs on **Switch Rack PoE** (US624P @ `10.10.200.232`), managed declaratively by `infra/ansible/playbooks/usw-acls.yml` (`/proxy/network/v2/api/site/default/acl-rules`). Switch default is allow-all, so these are explicit BLOCK overrides + one preserved ALLOW:

| # | Action | Flow | Purpose |
|---|--------|------|---------|
| 0 | ALLOW | Hue bridges (`204.51/52`) → Clients/202 | Return path for Clients→Hue control |
| 1 | BLOCK | Security/205 → 201, 202, 209, 210 | Switch-side complement to the Security UDM zone (covers switch-routed dests the zone can't) |
| 2 | BLOCK | Ceph/210 → vSAN/209 | Separate storage backends, no cross-talk |
| 3 | BLOCK | Clients/202 → Ceph/210 | No client workflow needs raw Ceph |
| 4 | BLOCK | vSAN/209 → Ceph/210 | Separate storage backends |

**Deliberately NOT blocked** (allow-all default preserves them): Servers↔Clients, Servers→vSAN/Ceph (K8s RBD + CNPG), Clients→vSAN (10G NAS/video editing). K8s↔Ceph runs **intra-VLAN-210 (L2)** and never hits an ACL. Design + rollout detail: `docs/planning/l3-switch-acl-iac-2026-05-28.md`.

---

## Complete VLAN Inventory

### Networks Routed by UDM Pro

| VLAN | Name | Subnet | Live Zone | Purpose |
|------|------|--------|-----------|---------|
| (untagged) | Default | 10.10.199.0/24 | Internal | Untagged native — should be empty, but DHCP `.100-.254` is still on. Talk service listens on `10.10.199.1` (see `unifi-talk.md`). |
| 200 | Management | 10.10.200.0/24 | Internal | Network equipment (UDM, switches, APs) |
| 204 | IoT | 10.10.204.0/24 | **IoT (custom)** | Smart home devices |
| 205 | Security | 10.10.205.0/24 | Internal | SimpliSafe gear (cameras retired) — Network Isolation = ON (see §"Known anomalies") |
| 206 | Guest | 10.10.206.0/24 | Hotspot (built-in) | Guest WiFi |
| 212 | Unifi | 10.10.212.0/24 | **Infrastructure (custom)** | UniFi Protect cameras (~13), Talk phones (3 UVP-TOUCH), UniFi Access (UA-Gate, UA-Intercom), Protect controller `.10`. **Note: APs/switches are NOT here — they're on Management/200.** Moved to Infrastructure 2026-05-28 (M30 Phase 1). |
| 4040 | Inter-VLAN | 10.255.253.0/24 | Internal | Transit between UDM and L3 switch |

### Networks Routed by L3 Switch

| VLAN | Name | Subnet | Live Zone | Purpose |
|------|------|--------|-----------|---------|
| 201 | Servers | 10.10.201.0/24 | Internal | K8s nodes, DNS (MetalLB `.5/.6`), infra services |
| 202 | Clients | 10.10.202.0/24 | Internal | User laptops, phones |
| 209 | vSAN | 10.10.209.0/24 | Internal | Storage network (Proxmox/NAS) |
| 210 | Ceph | 10.10.210.0/24 | Internal | Dedicated Ceph storage (PVE mon `.41`, K8s nodes `.50-.60` via `enp6s22` MTU 9000). Migrated 2026-05-18 from VLAN 201. |

### Networks Not in the Architecture Tables but Present on the UDM

| Network | Live Zone | Notes |
|---------|-----------|-------|
| WireGuard WAN1 (192.168.3.0/24) | VPN | UDM-side remote-user-VPN pool, no clients connected. Tracked under M42 / future cleanup. |
| LTE WAN | External | Failover priority 4, never used. Tracked for retirement. |
| WAN1 / WAN2 | External | Frontier (primary), Spectrum (failover-only). |

### Static Routes (carried by both UDM and L3 switch)

| Destination | Purpose | Next-hop |
|-------------|---------|----------|
| 10.10.100.0/22 | AWS Environment | 10.10.201.20 (vpn-local VIP, on L3 switch) / 10.255.253.3 (from UDM) |
| 10.255.255.0/29 | WireGuard tunnel endpoint | same |
| 10.254.0.0/24 | WireGuard client tunnel | same |

Note: `routing.json` shows each AWS route exists **twice** — once with `gateway_type=switch` and once with `gateway_type=default` — so both routers carry the logical routes and the UDM hands transit to the L3 switch.

---

## Live Zone Inventory

UniFi Network creates a fixed set of built-in zones; you can add custom zones on top. Source: `zone-matrix.json`.

| Zone | Type | Member networks | Notes |
|------|------|-----------------|-------|
| **Internal** | built-in | Default, Management/200 | Default = `Allow All Traffic` within the zone. **Switch-routed VLANs (Servers/201, Clients/202, vSAN/209, Ceph/210, InterVLAN/4040) are NOT members of any UDM zone** — they're routed by the L3 switch and their inter-VLAN security is enforced by switch ACLs (see below). Only their north-south traffic transits to the UDM (via VLAN 4040). |
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

Decoded from `firewall-policies.json` + `zone-matrix.json`. There are **114 total policies**: 110 predefined (auto-generated UniFi boilerplate for zone defaults) and **4 user-authored**.

### Default behaviour from each source zone

| Source → Dest | Live default | Notes |
|---|---|---|
| Internal → Internal | **Allow All Traffic** | Every documented "Trusted/Infrastructure/Security" rule between 200/201/202/205/209/210/212/4040 is satisfied by this default. |
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

These are the **only** firewall rules that aren't predefined boilerplate. Source: `firewall-policies.json` (`predefined: false`).

| Rule | Source | Destination | Protocol/Port | Purpose |
|------|--------|-------------|---------------|---------|
| **Allow IoT to DNS** | IoT zone (10.10.204.0/24) | `DNS-Servers` IP group (10.10.201.5, 10.10.201.6) | TCP/UDP `DNS-Ports` (53) | Lets IoT devices resolve via Technitium without exposing the rest of Servers. |
| **Allow-Wireguard** | External UDP, any source | 10.10.201.20 (keepalived VIP) | UDP 9821 (`WG-Ports-Inbound` group) | Inbound WireGuard for site-to-site (backs the `Wireguard Local` port-forward). |
| **Allow-Twilio-SIP-6767** | External UDP, `Twilio Signal IPs` group | Gateway zone (UDM itself) | UDP 6767 | Twilio SIP termination for UniFi Talk. Destination is the UDM (`10.10.199.1`), not a LAN host. |
| **Allow-Twilio-Media-10000-60000** | External UDP, `Twilio Media IPs` group | Gateway zone (UDM itself) | UDP 10000-60000 | Twilio media (RTP) for UniFi Talk. |

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
| `Twilio-SIP` | UDP inbound | 6767 | 10.10.199.1 (UDM Talk service) | `unifi-talk.md` |
| `Twilio-Media-Signal` | UDP inbound | 10000-60000 | 10.10.199.1 (UDM Talk service) | `unifi-talk.md` |
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

1. **Security/205 Network Isolation = ON + DHCP DNS empty.** Network Isolation at L2 prevents any inter-VLAN traffic regardless of zone policy. With no DHCP DNS, SimpliSafe gear has no resolver. Either disable isolation + set DNS to .5/.6, or document the deliberately-blank choice. Tracked: audit P1 #6 / M30-adjacent.
2. **Internal → Hotspot is Allow All.** Anything on the Servers VLAN can reach guest devices. Practical risk: low (guests ephemeral). Documented intent was Deny. Tracked: audit P2 #11.
3. **VPN zone is wired but unused.** WireGuard WAN1 (192.168.3.0/24) has no clients. VPN → Internal is Allow All; if the pool is ever populated, those clients get full LAN reach with no policy in place. Tracked under the M42 cleanup decision.
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

The matrix shows each (source, destination) zone pair as a cell; click into a cell to see/add policies for that flow. Built-in zones (Internal, External, Gateway, VPN, Hotspot, DMZ) cannot be deleted. Custom zones (today: `IoT`) are managed under the same Firewall page.

If you are adding a new policy:

1. Open the matrix cell for the relevant (source, destination) pair.
2. Click **Create Policy**.
3. For source/destination, prefer **Network Objects** / **Port Groups** under `Settings > Profiles` over hard-coded IPs — keeps future renumbering cheap. Today only 3 IP groups and 2 port groups exist; expanding this catalogue is tracked under audit P2 #12.
4. Set `Connection State: All` unless you specifically need to scope to new/established.
5. Save and verify by watching `System Log` → `Triggers` for hits.

**Before disabling Network Isolation on any network**, check what relies on it. With Internal → Internal currently `Allow All`, the only network whose isolation actively matters is Security/205 (see Known anomalies #1).

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

### From a Servers/Clients/Management host (Internal zone)

```bash
# Should work — Internal → Internal is Allow All
ping 10.10.200.1       # Management gateway
ping 10.10.205.10      # Anything in Security/205 (zone is Internal)
ping 10.10.212.5       # Anything in Unifi/212

# Should FAIL — Internal → IoT is Block All by default (no allow)
ping 10.10.204.51      # Hue bridge or similar
```

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
| Security/205 device can't resolve | Network Isolation = ON + DHCP DNS empty | See Known anomalies #1. Either disable isolation + set DNS, or move .205 into a future custom zone with a DNS allow rule. |
| Can't reach UDM management | Gateway zone access blocked | Don't add deny rules to `Internal → Gateway`. |
| Traffic between Servers/Clients/vSAN/Ceph isn't filtered | Those VLANs route off the L3 switch — UDM never sees the traffic | Use L3 switch ACLs — now deployed via `usw-acls.yml` (M52). |
| Guest reaches internal device | Internal → Hotspot is currently Allow All | See Known anomalies #2. |

### Verify zone assignment

`Settings` → `Networks` → click the network → check **Zone** field. Only VLAN 204 should show a custom zone (`IoT`); everything else shows `Internal`, plus Guest in `Hotspot`.

---

## References

- `docs/planning/udm-audit-2026-05-23.md` — read-only audit that drives this doc (Part 1)
- `docs/planning/firewall-zones-future-state.md` — proposed migration to a multi-zone design
- `docs/planning/outstanding-work.md` — M30 (reconcile zone arch), M42 (VPN cleanup)
- `/tmp/unifi-state/` — live state dump from `scripts/unifi/dump-state.sh` (regenerate to refresh)
- [UniFi Zone-Based Firewalls — Ubiquiti Help Center](https://help.ui.com/hc/en-us/articles/115003173168-Zone-Based-Firewalls-in-UniFi)
- [Migrating to Zone-Based Firewalls](https://help.ui.com/hc/en-us/articles/28223082254743-Migrating-to-Zone-Based-Firewalls-in-UniFi)
