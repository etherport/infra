# Networking — production best-practices review (2026-05-31)

Context: done immediately after the M18/M36 BGP migration completed. The current posture is already fairly mature; this review surfaces the **remaining** opportunities, prioritized. Items marked **[verify]** are candidates I haven't yet confirmed live.

## Current strengths (confirmed this session)
- **Zone-based firewall** (M30) — 157 policies; **IDS/IPS in `ips` (prevention) mode**; DPI enabled.
- **Hybrid L3 routing** — Switch Rack PoE (US624P) line-rate east-west for storage/compute (201/202/209/210); UDM north-south + zones. Textbook (UDM is CPU-bound; switch fabric ~50 Gbps).
- **MetalLB BGP** (eBGP to UDM, no ARP/MAC churn), **static routes codified** (`routes.tf`), **WG site-to-site** with VRRP failover (wg-failover hardened 2026-05-31).
- cert-manager wildcard (auto-renew via CF DNS-01), SOPS+age (now CI-capable), daily UDM-controller + Velero backups.
- Storage on dedicated NICs (Ceph/210 + NAS/209), MTU 9000.

## Opportunities (prioritized)

### P1 — worth doing
1. **Servers/201 → dedicated `Trusted` zone (M56).** Currently in the permissive `Internal` zone; least-privilege segmentation for the K8s/infra subnet is the production norm. Pre-staged allow-matrix already in M56.
2. **Confirm inter-zone default is deny-by-default. [verify]** 157 policies exist; production standard is default-deny + explicit allows. Verify no broad allow-by-default between zones (esp. IoT/Security → Trusted, Guest egress).
3. **DDNS is broken (task #84). [confirm]** DDNS writers reportedly still target the deleted Route53 zone → WAN-IP records not updating. Migrate to the CF API. Real correctness gap if still true.

### P2 — observability + IaC durability
4. **UDM/network telemetry → Prometheus (M55 unifi-poller).** No client/throughput/port/PoE/WAN metrics today — only reachability probes + `unifi_backup_*`. Logs reach Loki; metrics are thin.
5. **Enable NetFlow** (currently **disabled**) — traffic visibility / anomaly detection. Low-effort UI/API toggle; pairs with M55.
6. **Expand UDM-config IaC via the v2-API Ansible pattern.** Much of the UDM (zones, `gateway_type`, BGP—M58) isn't in the paultyng TF provider but *is* reachable via the `udm-firewall.yml`/`usw-acls.yml` v2-API pattern. Opportunity: codify the zone assignments + routing-assignment so the whole gateway config is reproducible, not just backup-restorable.

### P3 — resilience / likely accepted homelab risk (flag SPOFs)
7. **Single WAN** (`47.159.189.5`) — no ISP failover. A 2nd WAN (LTE/secondary ISP) is the production answer; hardware/cost-dependent, likely accepted. Flag the SPOF.
8. **Single UDM gateway — no HA.** SPOF for north-south + UDM-routed VLANs. Blast radius is bounded: the L3 switch keeps storage + intra-fabric east-west alive if the UDM is down, and controller-backup restore is fast. Document the failure mode + restore runbook.
9. **Dedicated LB VLAN (vs VIPs on 201).** Now that BGP works, moving the MetalLB pool to a dedicated UDM-routed `lb` VLAN would remove the intra-201 ARP nuance entirely and cleanly segment service VIPs. Minor — current setup works (kube-proxy handles intra-201).

## Cross-refs
M55 (unifi-poller), M56 (Trusted zone), M58 (UDM BGP→IaC), task #84 (DDNS). Audit baseline: `docs/planning/udm-audit-2026-05-23.md`, `docs/architecture/firewall-zones.md`.
