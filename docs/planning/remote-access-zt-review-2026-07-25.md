# Remote-access topology + zero-trust review — 2026-07-25

Point-in-time audit (repo IaC inventory + live cluster probe, both read-only) run after
the 2026-07-25 changes: CF Access removed from `plex.wind` (commit `4fbf5f6`, applied),
and the TS subnet-router primary-steal fix (M149 — K8s Connector is now the **sole**
`10.10.192.0/19` advertiser). Operating model under review: **Tailscale = primary remote
access, WireGuard = backup, CF tunnel = per-service fallback; every remotely-accessed
resource should take the shortest path to its host.**

## 1. Access-path matrix (as of this review)

| Path | Transport | Terminates | Status |
|---|---|---|---|
| TS → `10.10.192.0/19` | TS mesh → K8s Connector `k8s-homelab-router` | subnet-router pod (k8s-w2) | ✅ PRIMARY — sole advertiser, `PrimaryRoutes` verified |
| TS → `10.10.100.0/22` (AWS) | TS → `vpn-aws` | AWS edge t4g.small | ✅ correct scope (no more /19) |
| TS dedicated nodes | `plex`, `ntfy`, `cue-api`×2, `cue-db`, `remediation-approve` ts.net LBs | operator proxy pods | ⚠️ see §4 (cue-db on tailnet; plex-ts redundant) |
| WG backup | UDM `:9821` → VIP `10.10.201.20` (keepalived: k8s pod prio 150 / vpn-fallback 100) | WG pod or VM | ✅ proven failover (L33) but **no VRRP/VIP-holder alert** |
| CF tunnel | edge → cloudflared → svc | per-hostname | ✅ all SSO-gated except `plex.wind` (deliberate) |
| Exit nodes | k8s Connector, vpn-aws, vpn-fallback | full-tunnel egress ×3 | ⚠️ audit intent (§4) |

DNS: split-horizon healthy — internal names → Traefik VIP `10.10.201.70`; `auth.wind`
correctly absent from public DNS; TS split-DNS = `10.10.201.5/.6/10.10.100.10` (all
reachable through the advertised routes).

## 2. What the incident taught us (context for the fixes)

Tailscale control **re-elects the subnet-route primary on every advertiser change**, with
a fixed preference `vpn-aws > vpn-fallback > k8s-router` (the K8s router wins only as sole
advertiser; re-advertising a standby steals primary with **no failback**). The documented
"HA standby routers" design therefore silently produced: vpn-aws primary = every TS client
hairpinning homelab traffic through AWS (days, unnoticed); vpn-fallback primary = MetalLB
VIP blackhole (VLAN-201 BGP gap). WG HA (VRRP) behaves correctly; TS "HA" is a footgun.
Standby adverts were removed live; break-glass = `sudo tailscale set
--advertise-routes=10.10.192.0/19` on vpn-fallback (restores SSH/direct-IP, not VIPs).

## 3. Verified-healthy (no action)

- TS `/19` primary = K8s router; **no active DERP-relayed peers** at probe time; UDP
  direct works (nearest DERP LA 5.3ms from the cluster).
- CF exposure: 10 public hostnames, 9 SSO/service-token gated, only `plex.wind` direct
  (by design); everything else NXDOMAIN publicly.
- SA-token hygiene in spot-checked app namespaces (plex/ollama/home-automation/wikijs):
  `automountServiceAccountToken: false` everywhere.
- cert-manager wildcards both Ready (6-day LE profile renewing normally).
- hostNetwork/privileged pods confined to expected infra — **except home-assistant (§4.1)**.

## 4. Fix queue (severity-ranked; tracker IDs assigned)

1. **H46 (HIGH) — home-assistant: `privileged: true`, no PSS enforce label, no netpol
   tier, edge-reachable.** The single most exposed app pod: huge integration surface,
   deliberately not behind Authentik, root-equivalent on its node if popped, free
   east-west reach. Actions: try to de-privilege (or document why not), add PSS label,
   include in the netpol-tier work.
2. **M150 (MED) — TS standby-advert config still in IaC.** `infra/ansible/playbooks/
   tailscale.yml` + the `tailscale-failover` unit on vpn-fallback still configure `/19`
   standby advertising — an ansible re-run resurrects the M149 misconfig. Remove from
   IaC; rewrite `docs/architecture/vpn-tailscale.md` (diagram + failover sections
   describe the removed design); add the break-glass runbook.
3. **M153 (MED) — path-health alerting.** (a) alert when the TS `/19` primary ≠
   `k8s-homelab-router` (the 3-day silent hairpin must page next time); (b) L33
   follow-up: VRRP "VIP holder changed" / backup-not-ready alert. Likely one advisor/
   textfile-exporter check each.
4. **M151 (MED) — netpol tiers for credential-bearing namespaces.** Coverage is 6/39;
   highest-value next tiers: `flux-system`, `velero`, `backups`, `tailscale`,
   `cert-manager`, `garage` (+ `plex` = M147, `home-automation` = H46).
5. **M152 (MED) — tailnet surface audit.** (a) `cue-db` (Postgres!) is a tailnet node —
   confirm TS ACLs scope it to the cue app only (ACLs in `infra/tailscale/policy.hujson`
   currently allow-all ⇒ they don't); (b) verify device **`abacus`** (Windows, joined
   07-02, online) is known/expected; expire stale nodes (iPad offline since 07-08, mini
   key); (c) exit-node intent audit (three full-tunnel egress points); (d) decide fate of
   the redundant `plex-ts` LB (plex.wind now works over TS subnet-router AND un-gated CF).
   Durable fix = **L34** (TS ACL/settings into IaC) — still blocked on operator minting a
   TS API key/OAuth client.
6. **M147 (queued) — plex netpol tier.** M148 (queued) — CF rate-limit on Plex login.
7. **LOW — PSA label sweep** (12 unlabeled namespaces, incl. monitoring/velero/tailscale;
   only unifi-poller is `restricted`); extend gradually after netpol tiers.
8. **INFO — plex `/identity` publicly fingerprints the server version** — inherent to
   un-gated Plex; mitigation = Renovate keeps the image current (it does). **User action:
   enable 2FA on the plex.tv account.**

## 5. Checklist verdict vs the operating model

- "TS primary, WG backup" — **true and now correctly wired**, but *unmonitored* (fix #3).
- "Shortest path per resource" — true after the M149 fix (no AWS hairpin, no VIP
  blackhole). Residual: on-LAN TS clients still route VIP traffic through the subnet-
  router pod (LAN-speed, encryption-hop cost only); Mac↔homelab currently direct, DERP
  home NYC only matters during flap windows.
- "Primary/fallback not flapping" — TS: sole-advertiser makes flap *impossible* (the
  trade: no auto-failover — break-glass is manual, documented). WG: VRRP auto-failover
  retained and proven.

*Full audit transcripts: session task #74 (2026-07-25). Superseded design history:
`docs/architecture/vpn-tailscale.md` pending rewrite (M150).*
