# Firewall Zones and Policy

The **live** zone-based firewall + routing design for the `wind` homelab. This describes the
**current state**; the chronology of how it got here (M30 zones, M52 switch ACLs, the BGP/201
move, M56 Trusted/Management, the Twilio→asterisk cutover) lives in
[`archive/firewall-zones-migration-history.md`](archive/firewall-zones-migration-history.md).

> **Controller:** UniFi Network 9.4.x on UniFi OS 5.1.12, v10 **Zone-Based Firewall**
> (`ZONE_BASED_FIREWALL`; the legacy `rest/firewallrule` endpoint is empty).

---

## Overview

Security is enforced in two complementary places, by design:

1. **UDM Pro ("Windroute") — north-south + most east-west.** A v10 **zone-based** firewall. On top of
   the built-in zones (Internal, External, Gateway, VPN, Hotspot, DMZ) there are **five custom zones** —
   **Trusted** (Servers/201), **Management** (200), **IoT** (204), **Infrastructure** (Unifi/212),
   **Security** (205). Policy is codified in `infra/ansible/playbooks/udm-firewall.yml` (`udm_firewall_policies`,
   v2 API) — ~20 zone policies + supporting address/port groups — and **drift-checked daily** by
   `ansible-drift-detection.yml`.
2. **L3 switch ("Switch Rack PoE", US624P) — storage/client east-west.** Clients/202, vSAN/209 and Ceph/210
   are **gatewayed by the switch**, not the UDM (kept off the CPU-bound UDM for 10G/jumbo line-rate). Traffic
   **between** those three never reaches the UDM, so it's policed by **IP ACLs on the switch**
   (`infra/ansible/playbooks/usw-acls.yml`).

**Key fact:** **Servers/201 is UDM-routed** (its gateway is the UDM `10.10.201.1`) — so *all* of its
inter-VLAN traffic transits the UDM and is governed by the `Trusted` zone. The switch is the sole
enforcement point **only** for 202↔209↔210. (This is the routing invariant the `network-topology-drift.yml`
detector asserts.)

The UDM firewall is one of four independent connectivity-gating layers in the homelab (UDM zones · PVE host
firewall · Cilium NetworkPolicy · CF Access/Authentik) — see `CLAUDE.md §5`.

---

## Network architecture (dual-router)

Routing is split between the UDM (primary router/firewall/NAT) and the L3 switch (secondary router for the
storage/client fabric), joined by the **VLAN 4040** inter-VLAN transit.

```
                                         INTERNET (WAN)
                                                │
                                                ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                          UDM Pro ("Windroute")  — primary router/firewall/NAT     │
│   Gateway for: Default(199), Management(200), Servers(201), IoT(204),             │
│                Security(205), Guest(206), Unifi(212), Inter-VLAN(4040)            │
└─────────────────────────────────────────────────────────────────────────────────┘
   │        │         │         │         │         │         │         │
   ▼        ▼         ▼         ▼         ▼         ▼         ▼         ▼
 Default  Mgmt(200) Servers   IoT(204) Security  Guest(206) Unifi(212) 4040
 (199)    Management (201)     IoT      (205)     Hotspot    Infra      Transit
 Internal  (custom)  Trusted   (custom) Security              (custom)  Internal
                     (custom)           (custom)
                                                                         │ 4040 transit
                                              UDM 10.255.253.1 ◄────────► │ L3 switch 10.255.253.3
                                                                         │
                                                                         ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                     L3 Switch ("Switch Rack PoE")  — secondary router             │
│   Gateway ONLY for: Clients(202), vSAN(209), Ceph(210)                            │
│   Static routes to AWS (10.10.100.0/22, 10.255.255.0/30, 10.254.0.0/24)           │
└─────────────────────────────────────────────────────────────────────────────────┘
         │                  │                 │
         ▼                  ▼                 ▼
     Clients(202)        vSAN(209)         Ceph(210)
     Internal            Internal          Internal
```

**Where each flow is enforced:**

| Traffic | Enforcement |
|---|---|
| Servers/201 to/from anything (other VLAN or Internet) | **UDM** (`Trusted` zone) — 201 is UDM-routed |
| Any UDM-routed VLAN ↔ another (200/201/204/205/206/212) | **UDM** zone firewall |
| Switch-routed ↔ UDM-routed (e.g. Clients/202 ↔ Servers/201) | **UDM** zone firewall (transits the UDM via 4040) |
| **Between** switch-routed VLANs (202↔209↔210) | **L3 switch ACLs** (`usw-acls.yml`) — never touches the UDM |
| K8s ↔ Ceph | **Neither** — intra-VLAN-210 (L2), no L3 boundary |
| Proxmox/K8s → vSAN/209 storage | **Neither** — direct node↔NAS NIC, L2 |
| Anything ↔ Internet | **UDM** |

---

## Zones

UniFi creates a fixed set of built-in zones; custom zones sit on top. The five custom zones:

| Zone | Type | Members | Posture |
|------|------|---------|---------|
| **Trusted** | custom | Servers/201 | Trusted workload tier. Broad egress (External, Gateway, Vpn, Internal, Infrastructure, Management) + ingress for the service paths it fronts. |
| **Management** | custom | Management/200 | **Contained** admin plane — may reach only External, Gateway, `Trusted` (DNS to `.5/.6` + syslog to Alloy `.73`). Ingress from `Trusted` (cluster admins the UDM/devices), `Vpn`, `Gateway`. Default-denied to IoT/Guest/Security. |
| **IoT** | custom | IoT/204 | Default block to other zones; one explicit `Allow IoT to DNS`. |
| **Infrastructure** | custom | Unifi/212 | Protect/Talk/Access appliance fleet. `Internal↔Infrastructure Allow All` (broad — tightening is a deferred follow-up); →Gateway/→External auto-created. |
| **Security** | custom | Security/205 | SimpliSafe. Default block to all other zones; →External + →Gateway allowed (monitoring + DHCP/DNS). No internal-DNS rule. L2 Network Isolation retired — the zone is sole enforcement. |

Built-in zones in use: **Internal** (Default/199 only; `Internal→Internal Allow All`), **External**
(WAN1/WAN2/LTE; inbound blocked + named exceptions), **Gateway** (the UDM itself), **VPN** (the UDM backup
WireGuard tunnel; see note), **Hotspot** (Guest/206), **DMZ** (unused).

> **Custom zones default intra-zone to BLOCK** (the built-in `Internal` has a predefined intra-zone Allow;
> custom zones do not). This bites `Trusted` on **hairpin routes** — the AWS static route's next-hop
> `10.10.201.20` is back inside 201, so the UDM sees `Trusted→Trusted` and drops it (symptom:
> `dns-aws`/`vpn-aws` `TargetDown`). The explicit `Trusted → Trusted` allow in `udm-firewall.yml` fixes it.

> **VPN zone clarification.** The `Vpn` zone holds **only the UDM's built-in backup WireGuard tunnel**. The
> **primary** k8s + `vpn-local` WireGuard runs on Servers/201 behind the Keepalived VIP `10.10.201.20`
> (in `Trusted`): inbound via `External → Trusted (WireGuard) udp/9820-9821 → .20`, client traffic
> intra-`Trusted`. So the primary VPN does **not** depend on the `Vpn` zone; the `Vpn→Trusted/Management`
> allows (scoped TCP on `Vpn-Admin-Ports`, M42) keep the *backup* tunnel reaching servers/mgmt.

---

## VLAN inventory

### Routed by the UDM Pro

| VLAN | Name | Subnet | Zone | Purpose |
|------|------|--------|------|---------|
| (untagged) | Default | 10.10.199.0/24 | Internal | Untagged native — should be empty (DHCP `.100-.254` still on). Talk listens on `10.10.199.1`. |
| 200 | Management | 10.10.200.0/24 | **Management** | Network equipment (UDM, switches, APs). Contained admin plane. |
| 201 | Servers | 10.10.201.0/24 | **Trusted** | K8s nodes, DNS (MetalLB `.5/.6`), infra services. **UDM-routed** (gateway = UDM `10.10.201.1`). |
| 204 | IoT | 10.10.204.0/24 | **IoT** | Smart-home devices. |
| 205 | Security | 10.10.205.0/24 | **Security** | SimpliSafe (cameras retired). DHCP DNS empty — see anomalies. |
| 206 | Guest | 10.10.206.0/24 | Hotspot | Guest WiFi (public resolvers). |
| 212 | Unifi | 10.10.212.0/24 | **Infrastructure** | UniFi Protect (~13 cams), Talk phones (3 UVP-TOUCH), UniFi Access (UA-Gate, UA-Intercom), Protect controller `.10`. **APs/switches are NOT here — they're on Management/200.** |
| 4040 | Inter-VLAN | 10.255.253.0/24 | Internal | UDM↔L3-switch transit. |

### Routed by the L3 switch

Gateway = the switch. Inter-VLAN traffic **between** these three never touches the UDM → switch ACLs are
its sole enforcement.

| VLAN | Name | Subnet | Purpose |
|------|------|--------|---------|
| 202 | Clients | 10.10.202.0/24 | User laptops, phones. |
| 209 | vSAN | 10.10.209.0/24 | Storage network (Proxmox/NAS). |
| 210 | Ceph | 10.10.210.0/24 | Dedicated Ceph (PVE mon `.41`, K8s nodes `.50-.60` via `enp6s22` MTU 9000). |

### Also present on the UDM (not in the tables above)

| Network | Zone | Notes |
|---------|------|-------|
| WireGuard WAN1 (192.168.3.0/24) | VPN | UDM remote-user-VPN pool, no clients connected. |
| LTE WAN | External | Failover priority 4, never used — slated for removal. |
| WAN1 / WAN2 | External | Frontier (primary), Spectrum (failover). |

### Static routes (UDM-carried)

| Destination | Purpose | Next-hop |
|-------------|---------|----------|
| 10.10.100.0/22 | AWS Environment | 10.10.201.20 (vpn-local/keepalived VIP on Servers/201) |
| 10.255.255.0/30 | WireGuard tunnel endpoint (AWS) | same |
| 10.254.0.0/24 | WireGuard client tunnel | same |

Each route is carried **once**, `gateway_type=default`, `gateway_device = Windroute` (the UDM) — there is
no `gateway_type=switch` duplicate (verified live via the UDM `routing` API).

---

## Firewall policies

The bulk of zone-to-zone policies are UniFi-predefined boilerplate. The **user-authored** policies (live:
**28** `predefined:false`) are codified in `udm-firewall.yml` (`udm_firewall_policies`) — the
Trusted/Management/Infrastructure zone allows, IoT/Hotspot→Trusted DNS, External→Trusted WireGuard, Vpn
admin, syslog, trusted-admin-clients→Management, etc. A few **legacy** UI-only rules remain (the Twilio-6767
pair below).

### Notable default zone behaviour

| Source → Dest | Default | Note |
|---|---|---|
| Internal → Internal | Allow All | Internal holds only Default/199 now. |
| Internal → IoT | **Block All** | Servers can't initiate to IoT (no allow exists — e.g. HA→Hue needs one). |
| Internal → Hotspot | Allow All | Permissive (low risk; documented intent was Deny — anomaly #2). |
| IoT → Internal | Block + `Allow IoT to DNS` | Correctly isolated. |
| External → Internal | Block + named exceptions (Twilio, WireGuard, SLAAC/RA) | Standard WAN posture. |
| VPN → Internal | Allow All | UniFi default; inert (no VPN clients; trusted VLANs are no longer in `Internal`). |

### User-authored allow rules + groups

| Rule | Source | Dest | Port | Purpose |
|------|--------|------|------|---------|
| **Allow IoT to DNS** | IoT/204 | `DNS-Servers` (10.10.201.5/.6) | TCP/UDP 53 | IoT resolves via Technitium without exposing Servers. |
| **Allow-Wireguard** | External UDP, any | 10.10.201.20 (VIP) | UDP 9821 | Inbound site-to-site WireGuard. |
| **Allow-Twilio-SIP-6767** ⚠️ LEGACY | External, `Twilio Signal IPs` | Gateway (UDM) | UDP 6767 | **Vestigial** — the old direct Twilio→UDM-Talk path. Twilio now terminates on the asterisk-sbc (`.40`, 5061/TLS) via the port-forwards. Cleanup candidate. |
| **Allow-Twilio-Media-10000-60000** ⚠️ LEGACY | External, `Twilio Media IPs` | Gateway (UDM) | UDP 10000-60000 | **Vestigial** — old UDM-Talk media range. Cleanup candidate. |

Groups: `DNS-Servers` (addr, 2 IPs), `DNS-Ports` (port, 53), `Twilio Signal IPs` (addr, 8 /30s),
`Twilio Media IPs` (addr, 1 /18), `WG-Ports-Inbound` (port, 9821).

### Port forwards

| Rule | Proto/Port | Target | Source of truth |
|------|-----------|--------|-----------------|
| `Twilio-SIP` | **TCP 5061** | **10.10.201.40** (asterisk-sbc SIP bridge) | `infra/ansible/playbooks/asterisk-sbc.yml` |
| `Twilio-Media-Signal` | **UDP 10000-20000** | **10.10.201.40** (asterisk-sbc media) | `asterisk-sbc.yml` |
| `Wireguard Local` | TCP+UDP 9821 | 10.10.201.20 (VIP) | `platform/wireguard/README.md` |
| `Wireguard Travel` | UDP 9820 | 10.10.201.20 | **Disabled** (`enabled=false`) — should be deleted. |

---

## L3-switch ACLs (`usw-acls.yml`)

The switch-routed fabric (Clients/202, vSAN/209, Ceph/210) is policed by IP ACLs on Switch Rack PoE
(US624P `10.10.200.232`, `/proxy/network/v2/api/site/default/acl-rules`). Default is allow-all → explicit
BLOCK overrides + one preserved ALLOW.

| # | Action | Flow | Purpose |
|---|--------|------|---------|
| 0 | ALLOW | Hue bridges (`204.51/52`) → Clients/202 | Return path for Clients→Hue control |
| 1 | BLOCK | Security/205 → 201, 202, 209, 210 | Switch-side complement to the Security zone for the switch-routed dests **202/209/210**. ⚠️ The **→201 entry is DEAD** (205 & 201 are both UDM-routed → the flow never traverses the switch; the UDM Security zone blocks it). Prune in a switch-ACL review. |
| 2 | BLOCK | Ceph/210 → vSAN/209 | Separate storage backends |
| 3 | BLOCK | Clients/202 → Ceph/210 | No client needs raw Ceph |
| 4 | BLOCK | vSAN/209 → Ceph/210 | Separate storage backends |

**Deliberately NOT blocked** (allow-all preserves them): Servers↔Clients, Servers→vSAN/Ceph (K8s RBD +
CNPG), Clients→vSAN (10G NAS/editing). K8s↔Ceph is intra-VLAN-210 (L2) and never hits an ACL.

> ⚠️ The `usw-acls.yml` header + captured baseline **predate** the 201→UDM-routed move and still call 201
> switch-routed; any ACL row with 201 as src/dst is dead/redundant (above). Harmless — the UDM enforces the
> real boundary — but prune to 202/209/210 in a deliberate `--check`-verified pass.

---

## DNS pointers (per-VLAN DHCP)

Technitium primary/secondary `10.10.201.5` / `.6` is handed to Management/200, Servers/201, Clients/202,
IoT/204, vSAN/209, Ceph/210, Unifi/212. **Guest/206** gets public resolvers (`1.1.1.1`/`8.8.8.8`/`8.8.4.4`)
by design. **Default/199** and **Security/205** are empty (205 = the open M104 step, below).

---

## Known anomalies (live, tracked separately)

1. **Security/205 DHCP DNS empty** — Network Isolation is OFF (M104; zone model is sole enforcement), but
   the **DHCP DNS is still empty** (`dhcpd_dns_enabled=false`), so SimpliSafe has no LAN resolver. Remaining
   M104 step: set the Name Server to `.5`/`.6` (UI). Tracked: **M104**.
2. **Internal → Hotspot is Allow All** — Servers VLAN can reach guest devices. Low risk; intent was Deny.
3. **LTE WAN still configured** — failover priority 4, never carried traffic. Slated for removal.
4. **`Wireguard Travel` port-forward `enabled=false`** but still present — delete.
5. **Legacy Twilio user rules + the dead 205→201 switch ACL** — vestigial; cleanup candidates (above).

---

## Operating the firewall

**Edit policy via IaC, not the UI:** UDM zones/policies live in `udm-firewall.yml`; switch ACLs in
`usw-acls.yml`. **Always `--check --diff` first** (the playbooks full-reconcile) and apply via
`ansible-unifi.yml` — both are drift-checked daily (`ansible-drift-detection.yml`). The `unifi` TF provider
covers networks/reservations/port-forwards; zones + the `network_isolation_enabled` toggle are UI/ansible-only.

**UI navigation:** `Settings → Security → Firewall → Zone Matrix`. Click a (source, dest) cell to see/add
policies. Prefer Network Objects / Port Groups (`Settings → Profiles`) over hard-coded IPs. Verify hits via
`System Log → Triggers`.

### Quick connectivity tests

```bash
# From IoT/204: DNS allowed, Internal blocked
dig @10.10.201.5 google.com          # works (Allow IoT to DNS)
ping 10.10.201.50                    # blocked (IoT → Internal Block)

# From a Servers/201 host (Trusted): Infra/Gateway allowed, IoT/Security blocked
ping 10.10.212.5                     # works (Trusted → Infrastructure)
ping 10.10.205.10                    # blocked (no Trusted → Security allow)

# From Guest/206 (Hotspot): External allowed, Internal blocked
ping 8.8.8.8                         # works
ping 10.10.201.5                     # blocked
```

### Common issues

| Symptom | Cause → Fix |
|---|---|
| IoT can't resolve DNS | `Allow IoT to DNS` disabled or device not in 204 → check the `IoT → Internal` cell + device DHCP DNS. |
| Server can't reach a Hue/IoT device | `Internal → IoT` Block by default → add an explicit allow (none today). |
| Security/205 device can't resolve | DHCP DNS empty (anomaly #1) → set Name Server `.5`/`.6`. |
| Traffic between Clients/vSAN/Ceph isn't filtered | Those route off the L3 switch — the UDM never sees it → use the switch ACLs (`usw-acls.yml`). |
| Guest reaches an internal device | `Internal → Hotspot` is Allow All (anomaly #2). |

---

## Migration history

How this design was built (M30 zones · M52 switch ACLs · the BGP/201-routing move · M56 Trusted/Management ·
Twilio→asterisk · M104 isolation retirement) is archived in
[`archive/firewall-zones-migration-history.md`](archive/firewall-zones-migration-history.md).

## References

- [`archive/firewall-zones-migration-history.md`](archive/firewall-zones-migration-history.md) — completed-migration narrative
- `docs/planning/archive/udm-audit-2026-05-23.md` — the read-only audit this doc descends from
- `infra/ansible/playbooks/udm-firewall.yml` / `usw-acls.yml` — the IaC sources of truth
- `docs/planning/outstanding-work.md` — M104 (205 DHCP DNS), M42 (VPN cleanup)
- [UniFi Zone-Based Firewalls — Ubiquiti](https://help.ui.com/hc/en-us/articles/115003173168-Zone-Based-Firewalls-in-UniFi)
