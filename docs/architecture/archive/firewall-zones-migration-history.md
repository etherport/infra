# Firewall-zones migration history (archived)

> 📦 **Historical — completed migrations.** This captures *how the UDM firewall/zone/routing
> architecture got to its current shape*. It is **not** the live reference — for current state see
> [`../firewall-zones.md`](../firewall-zones.md). Kept so the rationale and dated decisions behind the
> live design are grep-able. Trackers: `docs/planning/outstanding-work.md` (M30, M52, M56, M104, M42).

All of the below is **done**. Newest first.

---

## Twilio voice path: UDM-Talk → asterisk-sbc (2026, completed)

**Then:** Twilio Elastic SIP Trunk terminated **directly on the UDM** (UniFi Talk), via UDM port-forwards
`UDP 6767 → 10.10.199.1` (SIP) and `UDP 10000-60000 → 10.10.199.1` (RTP), backed by two user firewall
rules (`Allow-Twilio-SIP-6767`, `Allow-Twilio-Media-10000-60000`, source = the Twilio Signal/Media IP
groups, dest = the Gateway zone).

**Now:** the external Twilio leg terminates on the **asterisk-sbc** (VM 1004, `10.10.201.40`) — **TCP 5061
(SIP-TLS) + UDP 10000-20000 (RTP)** — which bridges internally to UniFi Talk on `10.10.199.1:6767`. The
live port-forwards (`Twilio-SIP`, `Twilio-Media-Signal`) now target `.40`. The old `…-6767` /
`…-10000-60000` user firewall rules are **vestigial** (cleanup candidates) — external Twilio no longer hits
`:6767` on the UDM. Source of truth for the external leg: `infra/ansible/playbooks/asterisk-sbc.yml`
(+ the PVE firewall scoping in `infra/terraform/proxmox/firewall/standalone-vms.tf`, M77 Stage-2b).

## M104 — Security/205 Network Isolation retired (isolation OFF; zone model sole enforcement, 2026-06-29)

VLAN 205 (SimpliSafe) previously used the UI **Network Isolation** L2 toggle. Per the M104 decision it was
**disabled** (verified live `network_isolation_enabled=false`) so the `Security` UDM zone is the single
enforcement point. (Remaining open M104 step: set the 205 DHCP DNS — see the live doc's anomalies.)

## M56 — Trusted / Management zones (2026-05-31)

Enabled by the BGP migration making Servers/201 **UDM-routed** (see below). Split the former "everything
trusted lives in `Internal`" lump into two custom zones:
- **Trusted** = Servers/201 — broad egress, behaviour-neutral vs the old `Internal` so the move didn't
  change workload connectivity.
- **Management** = Management/200 — a **contained** admin plane (reaches only External/Gateway/`Trusted`),
  so a compromised workload/device can't pivot freely. Cost: a few explicit `Trusted↔Management` allows
  for the cluster's infra tooling (poller, gh-runner, backup, cert-sync).

**Gotcha discovered here (still live):** custom zones default **intra-zone to BLOCK** (the built-in
`Internal` has a predefined `Internal→Internal Allow All`; custom zones do not). This bit `Trusted` via a
**hairpin route** — the AWS static route's next-hop `10.10.201.20` is *back inside* 201, so the UDM
evaluated the flow as `Trusted→Trusted` and dropped it (`dns-aws`/`vpn-aws` `TargetDown`). Fix = the
explicit `Trusted → Trusted` allow in `udm-firewall.yml`.

**trusted-admin-clients → Management exception (2026-06-10, narrowed H34 2026-06-11):** the Mac mini ops
host (`10.10.202.101`, on switch-routed Clients/202) had no path into the contained Management zone, so
headless terraform-proxmox (mini → PVE `10.10.200.41:8006`) was dropped. Opened with a scoped rule —
`protocol: tcp` to `mgmt-admin-hosts` on `Mgmt-Admin-Ports` (22/443/8006), logged — risk-equivalent to the
existing `Vpn → Management` admin allow.

## BGP migration → Servers/201 became UDM-routed (M18/M36, ~2026-05-31)

The pivotal routing change. **Before:** Servers/201 was **switch-routed** (its gateway was the L3 switch),
so the UDM couldn't zone it — which is why M30 Phase 4 (a `Servers` zone) was originally skipped. The
**MetalLB BGP migration** moved 201's gateway to the **UDM** (`10.10.201.1`); verified live that every
inter-VLAN flow from a 201 host first-hops the UDM. That made 201 zone-able (→ M56 `Trusted`) and means all
201 inter-VLAN traffic now transits the UDM (the switch ACLs are no longer the enforcement point for any
201-involved flow — only for 202↔209↔210). The `usw-acls.yml` baseline + header still predate this and
call 201 switch-routed; rows with 201 as src/dst are dead/redundant (e.g. the `205→201` ACL) — to be
pruned in a deliberate switch-ACL review.

## M52 — L3-switch ACLs (2026-05-29)

vSAN/209 + Ceph/210 (and, at the time, Servers/201) are L3-switch-routed and can't be UDM-zoned, so their
east-west security lives in **IP ACLs on Switch Rack PoE** (US624P `10.10.200.232`), managed declaratively
by `infra/ansible/playbooks/usw-acls.yml` (`/proxy/network/v2/api/site/default/acl-rules`). Switch default
is allow-all → explicit BLOCK overrides (Security/205 isolation, storage-tier separation) + one preserved
ALLOW (Hue return path). Design detail: `docs/planning/archive/l3-switch-acl-iac-2026-05-28.md`.

**Why the hybrid split (still the rationale):** the UDM is CPU-bound (~3.5-5 Gbps); Switch Rack PoE is
~50 Gbps line-rate. Storage (vSAN/Ceph 10G + jumbo) + workstation→NAS flows MUST stay switch-routed for
performance, so their security is switch ACLs, not UDM zones. Textbook firewall-north-south /
L3-switch-east-west.

## M30 — zone migration (COMPLETE 2026-05-29)

Moved from a single trusted `Internal` lump to **custom zones**. Phases:
- **Phase 1 ✅** — custom `Infrastructure` zone; VLAN 212 (Protect+Talk+Access fleet) moved in (2026-05-28).
- **Phase 2 → M52 ✅** — vSAN/209 + Ceph/210 to L3-switch ACLs (above).
- **Phase 3 ✅** — custom `Security` zone; VLAN 205 (SimpliSafe) moved in (2026-05-29).
- **Phase 4 — SUPERSEDED by M56** — originally a `Servers` zone, skipped because 201 was switch-routed;
  the BGP migration then made 201 UDM-routed, so M56 delivered it as the `Trusted` zone.
- **Phase 5 ✅** — doc reconciled to live; planning companion archived
  (`docs/planning/archive/firewall-zones-future-state-2026-05-29-completed.md`).

**Historical note:** earlier revisions described a 6-custom-zone design that was never implemented — only
`IoT` existed pre-migration.

## v10 Zone-Based Firewall migration (2024-12-22)

The UniFi controller migrated from legacy per-rule firewall (`rest/firewallrule`) to the v10
**Zone-Based Firewall** (`ZONE_BASED_FIREWALL`). The legacy endpoint is now empty; all policy is
zone-matrix-based. This is the foundation the M30/M56 custom zones were built on.
