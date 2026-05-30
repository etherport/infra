# BGP migration — Phase B: move Servers/201 to UDM-routed

> **STATUS: PREP / NOT YET EXECUTED (drafted 2026-05-30).** Design + checklist only — no changes made. Execute *with* Graham present (it re-homes the K8s nodes' primary-VLAN gateway). Phase A (node 209 NICs) is ✅ complete, which is the prerequisite.

**Part of:** `docs/planning/metallb-bgp-migration-2026-05-29.md` §4–5 (M18/M36).
**Goal:** flip **Servers/201** from switch-routed (Switch Rack PoE, US624P @ `10.10.200.232`) to **UDM-routed** — `gateway_type: switch → default`. The `.1` gateway moves from the switch SVI to the UDM SVI (**same IP `10.10.201.1`**, so the K8s nodes need no reconfig). This unlocks Phase C/D (UDM↔MetalLB BGP → fixes the M36 IP-conflict alerts) and lets Servers/201 finally join a UDM firewall zone.

**Why it's safe to do now:** Phase A gave every NAS-workload node a direct 209 NIC, so `node→sequoia` NFS stays L2 on the switch fabric even after 201's gateway moves to the (CPU-bound) UDM. Ceph (210) and Clients↔NAS (202↔209) stay switch-routed, so the bulk storage + video-editing flows never touch the UDM.

---

## ⚠️ This is NOT a `terraform apply`
The per-VLAN routing assignment (`gateway_type`) is **not modeled** by the paultyng `unifi_network` provider (same gap class as zones/firewall/ACLs). Phase B is a **UniFi UI / v2-API change, captured in this doc**. The static L3 routes themselves *are* codified (`infra/terraform/unifi/routes.tf`, 6/6, zero drift) — but their next-hops must be re-verified after the move (see below).

---

## Step 0 — Capture the before-state (do this first, paste outputs into the PR/notes)
- UniFi → Settings → Networks → **Servers (201)**: screenshot the current routing/gateway-device setting (today: routed by Switch Rack PoE / `gateway_type=switch`).
- From a K8s node:
  ```
  ip route get 1.1.1.1            # default → 10.10.201.1 (today via the switch SVI)
  ip route get 10.10.202.x        # to a Clients host — note path
  ip route get 10.10.209.10       # MUST already egress enp6s23 (Phase A) — unchanged by Phase B
  traceroute -n 1.1.1.1           # first hop = .1; record the L2 path
  ```
- Confirm the routes.tf next-hops resolve **now**: `10.255.253.3` (WG) and `10.10.201.20` (WG VIP).
- Baseline cluster health: `kubectl get nodes`, CNPG `cnpg status`, `ceph -s` (via toolbox), `kubectl get pods -A | grep -v Running`.
- Note the current MetalLB LB VIPs + that they answer cross-VLAN (DNS `.5`, Traefik `.70`, Loki syslog `.73`).

## Step 1 — Flip 201 to UDM-routed
1. UniFi → Settings → Networks → **Servers (201)** → change the network's router/gateway from **Switch Rack PoE** to the **UDM (Default gateway)** — i.e. `gateway_type: switch → default`. Gateway IP stays `10.10.201.1`.
   - *(If done via v2 API instead of UI, PATCH the network object's `gateway_type` to `default`; capture the request/response in the PR.)*
2. Expect a brief (seconds) blip as the `.1` SVI re-homes from the switch to the UDM. Intra-201 node↔node is pure L2 and is **unaffected** (control plane stays up).

## Step 2 — Verify (the gate before Phase C)
- **Intra-201 (L2):** node↔node, API server, etcd all healthy — `kubectl get nodes` stays Ready, no CNPG failover.
- **North-south via UDM:** from a node, `ip route get 1.1.1.1` first hop `10.10.201.1`; internet reachable; `node→` a UDM-routed VLAN (e.g. Mgmt/200) works.
- **NAS path unchanged (the whole point of Phase A):** `ip route get 10.10.209.10` still egresses `enp6s23`; NFS mounts intact (`mount | grep sequoia`); Plex plays.
- **East-west path change to note:** Clients(202, still switch-routed)↔Servers(201, now UDM-routed) now **hairpins through the UDM** (202→switch→UDM→201). Verify it still works and throughput is acceptable for the actual 201↔202 flows (these are app/control, not bulk — bulk client↔NAS is 202↔209, untouched).
- **Routes still valid:** re-verify the routes.tf next-hops (`10.255.253.3`, `10.10.201.20`) resolve and the AWS/WG routes still work after the gateway move.
- **Cluster health:** CNPG primary stable, `ceph -s` HEALTH_OK, no new pending/crashlooping pods, MetalLB VIPs still answer cross-VLAN.

## Step 3 — (optional, same window) zone the now-UDM-routed 201
Servers/201 is currently zoneless (it never crossed the UDM). Once UDM-routed it *can* join a UDM firewall zone (e.g. `Trusted`). Optional and separable — only do it if you've thought through the zone policy; otherwise leave for a follow-up so Phase B's blast radius stays minimal.

## Rollback
Flip `gateway_type` back to `switch` (UI/API). The `.1` SVI re-homes to the switch; instant revert, no VIP/IP changes. Intra-201 never broke, so rollback only affects the north-south path.

---

## Risks / notes
- **Riskiest step of the whole migration** — it re-homes the nodes' primary-VLAN gateway. Have iKVM/console handy, low-use window, and Graham present.
- **UDM throughput:** UDM is CPU-bound ~3.5–5 Gbps vs the switch fabric ~50 Gbps. Acceptable *only because* Phase A + Ceph NIC keep bulk storage off the UDM. Do **not** move 202/209/210 to UDM-routed.
- **L3-switch ACLs (M52):** the switch ACLs that police 201↔{202,209,210} east-west assume 201 is switch-routed. After the move, 201↔202 traffic crosses the UDM instead of the switch — so that east-west pair is now policed by **UDM zones**, not the switch ACL. Re-check `infra/ansible/playbooks/usw-acls.yml` + `docs/architecture/firewall-zones.md` for any 201 rule that's now moot or needs a UDM-zone equivalent.
- **Gated next:** Phase C (BGP parallel with L2) only after Phase B verifies clean. Phase B alone delivers no MetalLB/M36 change — it's the enabler.
