# M52 — L3-Switch ACL IaC (design)

**Date:** 2026-05-28
**Status:** Design. No playbook written yet; this doc scopes it.
**Tracker:** **M52** in `docs/planning/outstanding-work.md` (replaces the dropped M30 Phase 2).
**Companion:** `docs/planning/firewall-zones-future-state.md` (UDM zone migration); `docs/architecture/firewall-zones.md` (live topology).

---

## 1. Why this exists

The UDM zone-based firewall only polices traffic that **crosses the UDM**. Four VLANs are routed entirely by **Switch Rack PoE** (US624P @ `10.10.200.232`, MAC `d8:b3:70:75:eb:df`) and their inter-VLAN (east-west) traffic never reaches the UDM:

| VLAN | Name | `gateway_type` |
|------|------|----------------|
| 201 | Servers | `switch` |
| 202 | Clients | `switch` |
| 209 | vSAN | `switch` |
| 210 | Ceph | `switch` |

So the only place to enforce security between these four is **switch ACLs**. This is the standard hybrid pattern (firewall = north-south + zones; L3 switch = east-west at line rate). Routing them through the UDM instead is not an option — UDM is CPU-bound at ~3.5-5 Gbps while the switch fabric is ~50 Gbps, and storage + 10G workstation→NAS flows need line rate.

M52 brings these ACLs under Ansible IaC so they survive a controller rebuild and are reviewable in git.

---

## 2. Switch capability (verified 2026-05-28)

From the live `/stat/device` record (`switch_caps`):

| Capability | Value | Meaning |
|------------|-------|---------|
| `max_custom_ip_acls` | 128 | **L3/IP ACLs supported** — what M52 uses |
| `max_custom_mac_acls` | 128 | MAC ACLs (not needed here) |
| `max_global_acls` | 128 | |
| `max_l3_intf` | 64 | confirms L3 routing role |
| `max_static_routes` | 256 | |
| firmware `version` | `7.5.2.16967` | |

> **⚠️ Jumbo-frame caveat (flagged, needs verification):** `jumboframe_enabled: False` on this switch. Ceph/210 uses MTU 9000 on `enp6s22`. **Open question:** does Ceph east-west traffic actually traverse Switch Rack PoE, or does it ride the separate 10G switch (Switch Rack 10G, USL8A)? If Ceph jumbo frames cross this switch with jumbo disabled, that's a pre-existing MTU problem independent of ACLs — investigate before adding any Ceph ACL rules. Capture in M52 pre-flight.

---

## 3. Current ACL state (captured 2026-05-28)

Endpoint: `GET /proxy/network/v2/api/site/default/acl-rules` — returned **2 hand-built rules**:

```
[0] ALLOW "Allow Client (202) to Hue"   proto=ALL
      FROM  IPS[10.10.204.51, 10.10.204.52]   (Hue bridges on IoT/204)
      TO    NETWORKS[Clients/202]
      → return-path allow so Hue bridge replies reach switch-routed Clients

[1] BLOCK "Isolate 205 Security (L3)"    proto=ALL
      FROM  NETWORKS[Security/205]
      TO    NETWORKS[Servers/201, Clients/202, vSAN/209]
      → switch-side complement to the UDM Security-zone isolation (Phase 3)
```

**Findings:**
- These were built manually in the UI — M52 must **import + preserve** them, not clobber.
- **Gap:** rule [1] blocks Security → {201, 202, 209} but **NOT Ceph/210**. Security→Ceph is currently open at the switch. M52 should close it (Security has no business reaching any storage).
- The existence of an explicit Hue return-**allow** [0] suggests the switch's inter-VLAN default may not be plain allow-all — **must verify** (see §4).

---

## 4. Open questions

1. **Switch default inter-VLAN behavior — allow-all or deny-all?** ✅ **RESOLVED (inferred): ALLOW-ALL.**
   Servers/201 ↔ Clients/202 and Servers → vSAN/Ceph all work *today* (K8s mounts Ceph RBD, NAS reachable from laptops) yet there is **no explicit ALLOW** rule for any of them — only the one Hue allow + one Security block. If the default were deny, those flows would be broken. Therefore the switch routes inter-VLAN with an implicit allow and ACLs are explicit **BLOCK overrides**. → M52 strategy: add explicit BLOCKs (matches the existing `Isolate 205` rule). *Confirm definitively during rollout via a zero-diff import of the 2 existing rules + one Clients→Servers connectivity probe.*
2. **ACL directionality + statefulness.** Switch IP ACLs are stateless and the existing rules are one-directional (`Isolate 205` blocks 205→dests only; Hue rule is return-path only). So **mutual blocks need a rule per direction** (e.g., vSAN↔Ceph = two rules). Factored into §5.
3. **ACL attach point.** The `acl-rules` v2 endpoint carries no port binding — appears **global** to the switch's L3 routing. Confirm on first apply (a global rule taking effect regardless of port = confirmation).
4. **Ceph MTU/path** (see §2 caveat) — still open; check before any Ceph-touching rule.

---

## 5. Target ACL set (final — default is allow-all, so only BLOCKs + the 2 existing rules)

Since the switch default is allow-all (§4.1), the "allowed" flows (Servers↔Clients, Servers→storage, Clients→vSAN) need **no rules** — they already work. M52 is a small, explicit set:

| # | Rule | Action | Source → Dest | Status |
|---|------|--------|---------------|--------|
| 1 | Allow Client (202) to Hue | ALLOW | Hue IPs `204.51/52` → Clients/202 | **existing — preserve** |
| 2 | Isolate 205 Security (L3) | BLOCK | Security/205 → Servers/201, Clients/202, vSAN/209, **Ceph/210** | **existing — extend** (add 210) |
| 3 | Block Clients to Ceph | BLOCK | Clients/202 → Ceph/210 | **new** — no client needs raw Ceph |
| 4 | Block vSAN to Ceph | BLOCK | vSAN/209 → Ceph/210 | **new** — separate backends |
| 5 | Block Ceph to vSAN | BLOCK | Ceph/210 → vSAN/209 | **new** — reverse of #4 (stateless → both dirs) |

That's it — 5 rules total (1 preserved, 1 extended, 3 new). Everything else stays default-allow.

**Deliberately NOT blocked** (would break things): Servers↔Clients, Servers→vSAN, Servers→Ceph (K8s RBD + CNPG), Clients→vSAN (10G video editing). Storage replication *within* a VLAN (vSAN↔vSAN OSDs, Ceph↔Ceph mons) is intra-VLAN L2 — never hits an ACL.

**Note on Clients→vSAN vs Clients→Ceph asymmetry:** Clients reach the NAS (vSAN) for file/video work but have no use for raw Ceph RBD/mon traffic — hence allow vSAN, block Ceph. Consistent with the storage-tier split.

---

## 6. Playbook design

`infra/ansible/playbooks/usw-acls.yml` — mirrors the proven `udm-firewall.yml` pattern:

- **Auth:** 1Password `UDM (tf-admin)` item → `/api/auth/login` → TOKEN cookie + CSRF (identical to udm-firewall.yml).
- **Endpoint:** `GET/POST/PUT/DELETE /proxy/network/v2/api/site/default/acl-rules`.
- **Resolution:** declare rules by VLAN name; resolve `network_ids` at runtime from `/rest/networkconf` (so rules survive rebuilds with new IDs — same approach as the zone-name resolution in udm-firewall.yml).
- **Reconcile:** match existing rules by `name`; create missing, update drifted (compare action/source/dest/protocol), leave others. Preserve the 2 hand-built rules by declaring them in the playbook vars (idempotent no-op once codified).
- **Declarative var shape** (sketch):
  ```yaml
  usw_acls:
    - name: "Allow Client (202) to Hue"
      action: ALLOW
      source: { type: IP_OR_SUBNET, ips: [10.10.204.51, 10.10.204.52] }
      destination: { type: NETWORK, vlans: [202] }
    - name: "Isolate 205 Security (L3)"
      action: BLOCK
      source: { type: NETWORK, vlans: [205] }
      destination: { type: NETWORK, vlans: [201, 202, 209, 210] }   # 210 added
    # ... + storage/compute matrix from §5
  ```
- **No `become`** (local CLI + HTTPS, same as udm-firewall.yml — run with `-e ansible_become=false`).

---

## 7. Test methodology + rollback

**Before applying:**
1. Resolve §4 open questions (esp. default allow/deny — gates the whole strategy).
2. Snapshot current ACLs to `docs/architecture/l3-switch-acl-state-2026-05-28.json` (raw `acl-rules` dump) as the rollback reference.
3. M31 UDM backup already covers controller config (ACLs are in the controller DB).

**Apply order (lowest blast radius first):**
1. First only the **additive/safe** rules: close the Security→Ceph gap (extend rule [1]). Verify SimpliSafe unaffected + storage health green.
2. Then the storage/compute matrix BLOCKs (Clients→Ceph, vSAN↔Ceph). **Highest risk** — a bad rule cuts K8s↔Ceph and trips CNPG/Velero within minutes. Apply one, soak, watch `kubectl get pods -A` + CNPG + Ceph health, then the next.

**Verification probes per rule:**
- Allowed flows: positive test (e.g., from a Clients host `nc -vz <vsan-host> <smb-port>`).
- Blocked flows: negative test (e.g., Clients→Ceph mon port should time out).
- Cluster health: `kubectl get pods -A | grep -v Running`, CNPG cluster status, Ceph `HEALTH_OK`.

**Rollback:** re-run playbook with the prior spec, or restore the 2-rule baseline from the captured JSON. Per-rule revert via DELETE on the rule `_id`.

---

## 8. Sequencing

1. ✅ Capture current state (this doc, §3).
2. Resolve §4 open questions (1 quick connectivity test + 1 Ceph-path check).
3. Write `usw-acls.yml` with the 2 existing rules first (prove idempotent import = zero changes).
4. Add the Security→Ceph gap-closer; apply + verify.
5. Add the storage/compute matrix incrementally; soak ≥7 days.
6. Phase 5 (zone-migration cleanup) can run in parallel — independent.
