# Archived runbooks — index

These runbooks describe **completed** one-time migrations/enablements. They're kept
for history (the "why" and the verification evidence), not as live procedure. For
current operations see [`../`](../) and [`../../README.md`](../../README.md).

## BGP migration (MetalLB L2 → eBGP), May 2026

Run in order A → B → C. End state: Servers/201 is UDM-routed north-south and the
UDM ↔ MetalLB eBGP session carries LoadBalancer VIPs (Traefik `10.10.201.70`, etc.).
See the [networking architecture](../../architecture/) for the live picture.

| Phase | Doc | Outcome |
|-------|-----|---------|
| A | [bgp-phase-a-209-node-interface.md](bgp-phase-a-209-node-interface.md) | ✅ 2026-05-29 — added the VLAN 209 (vsan) node interface (NAS stays on the 209 NIC) |
| B | [bgp-phase-b-201-udm-routed.md](bgp-phase-b-201-udm-routed.md) | ✅ 2026-05-30 — flipped Servers/201 `gateway_type: switch → default` (UDM-routed) |
| C | [bgp-phase-c-udm-metallb.md](bgp-phase-c-udm-metallb.md) | ✅ 2026-05-31 — UDM ↔ MetalLB eBGP, parallel with L2, then L2 retired |

## AI advisor (M41 / M45) — ⚠️ system is LIVE

These are the one-time **enable** runbooks; the advisor itself is active (advisory +
approve-via-email). Archived because enablement is done, not because it's retired.

| Doc | Purpose |
|-----|---------|
| [ai-advisor-phase1-enable.md](ai-advisor-phase1-enable.md) | Advisory-only diagnosis email path |
| [ai-advisor-phase2-enable.md](ai-advisor-phase2-enable.md) | Approve-via-email (HMAC-signed buttons) |
| [ai-advisor-phase3-enable.md](ai-advisor-phase3-enable.md) | Autonomous-execute (opt-in) |
| [ai-advisor-phase-b-cloudwatch.md](ai-advisor-phase-b-cloudwatch.md) | CloudWatch signal source |

## DNS / DDNS → Cloudflare migrations (Route53 retired 2026-05-27)

| Doc | Purpose |
|-----|---------|
| [cloudflare-ddns-migration.md](cloudflare-ddns-migration.md) | DDNS → Cloudflare |
| [ddns-updater-cf-migration.md](ddns-updater-cf-migration.md) | DDNS updater → Cloudflare |
| [cert-manager-dns01-cf-migration.md](cert-manager-dns01-cf-migration.md) | cert-manager DNS-01 → Cloudflare |
| [aws-private-dns.md](aws-private-dns.md) | AWS private DNS setup |
| [cloudflare-access-enable.md](cloudflare-access-enable.md) | Full-zone Route53→CF migration + CF Access (✅ 2026-05-27) |
| [ubiquiti-ddns-route53.md](ubiquiti-ddns-route53.md) | Router-side Route53 DDNS field layout (Route53 retired) |

## Other completed migrations

| Doc | Purpose |
|-----|---------|
| [ceph-vlan-migration.md](ceph-vlan-migration.md) | Ceph onto its dedicated VLAN (210) |
| [udm-network-app-modernization.md](udm-network-app-modernization.md) | UDM Network App API-key / Integration API |
| [cloudwatch-to-loki-enable.md](cloudwatch-to-loki-enable.md) | Ship CloudWatch logs → Loki |
| [alb-decom.md](alb-decom.md) | Decommission the AWS ALB |
| [postgres-barman-activation.md](postgres-barman-activation.md) | CNPG Barman backup activation (✅ live; restore → disaster-recovery §9) |

## Superseded by cairn (M103 — iCloud backup agent, 2026-06-25)

| Doc | Purpose |
|-----|---------|
| [macos-photos-backup.md](macos-photos-backup.md) | The retired M79 bash iCloud Photos pipeline |
| [mini-photos-export-observability.md](mini-photos-export-observability.md) | The old `photos_export_*` cluster-side metric/alert schema |
