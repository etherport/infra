# BGP migration — Phase C: UDM ↔ MetalLB eBGP (parallel with L2)

> ## ✅ DONE & VERIFIED 2026-05-31
> 8/8 node speakers `Established` to the UDM; all 5 MetalLB VIP /32s learned via BGP + installed (ECMP). Runs in parallel with L2 (L2 still primary until Phase D).

**Part of:** `docs/planning/metallb-bgp-migration-2026-05-29.md` (M18/M36). Prereqs: Phase A (209 NICs) + Phase B (Servers/201 → UDM-routed) — both ✅.

## What it does
MetalLB speakers (ASN **64513**) peer eBGP to the UDM (`10.10.201.1`, ASN **64512**) and advertise the LoadBalancer VIPs as /32 routes, instead of L2/ARP ownership. The UDM installs them as BGP routes (ECMP across the advertising nodes) → no ARP MAC-ownership → fixes the M36 `.5`/`.71` IP-conflict alerts (fully, once L2 is removed in Phase D).

## Cluster side — IaC (Flux), `platform/kubernetes/metallb/metallb-wind.yaml`
`BGPPeer` (`udm`, myASN 64513 / peerASN 64512 / peerAddress 10.10.201.1) + `BGPAdvertisement` (`primary-bgp`, pool `primary`, aggregationLength 32), alongside the existing `L2Advertisement`. Commit `68ff6a8`.

## UDM side — UI (NOT codifiable as an Ansible push; see "Durability")
UniFi Network 10.4.57 → **Settings → Routing → BGP** → create a config named **`metallb`** on device **Windroute**, with this FRR config (the source-of-truth artifact — re-upload verbatim on rebuild):

```
router bgp 64512
 bgp router-id 10.10.201.1
 no bgp ebgp-requires-policy
 neighbor metallb peer-group
 neighbor metallb remote-as 64513
 neighbor metallb password <BGP_MD5_KEY>
 bgp listen range 10.10.201.0/24 peer-group metallb
 address-family ipv4 unicast
  neighbor metallb activate
  neighbor metallb soft-reconfiguration inbound
 exit-address-family
```
- `listen range 10.10.201.0/24` accepts all 8 node speakers without listing each.
- `no bgp ebgp-requires-policy` is REQUIRED — without it FRR drops the eBGP-learned VIP routes.
- **`neighbor metallb password <BGP_MD5_KEY>` — L24 (2026-06-28): TCP-MD5 auth.** The peer-group
  password covers all 8 dynamic listen-range neighbors at once. `<BGP_MD5_KEY>` is the SAME value as
  the cluster secret **`bgp-md5`** (`platform/kubernetes/metallb/02-bgp-md5-secret.sops.yaml`, key
  `password`) referenced by `BGPPeer/udm` `spec.passwordSecret`. **Retrieve on rebuild:** `sops -d`
  that file (or `kubectl get secret -n metallb-system bgp-md5 -o jsonpath='{.data.password}' | base64 -d`).
  This is honored ONLY in MetalLB **FRR mode** (L24 migrated off the native kubespray addon for exactly
  this). ⚠️ Mismatch on EITHER end drops all sessions → VIPs withdraw (no L2 fallback since Phase 4).

## Verification (UDM UI: Routing → BGP, 2026-05-31)
- Config `metallb` / Windroute / **Enabled**.
- **Neighbors:** 8 `Established` — `.50/.51/.52` (cp1-3, Received 0 — they run no LB pods), `.53–.56` + `.60` (workers, Received 4–5), all Remote AS 64513.
- **Routes:** `10.10.201.5/32`, `.70/32`, `.71/32`, `.72/32`, `.73/32` — all `BGP`, `ECMP`, `Installed`, metric 20.
- Cross-check (cluster): speaker logs `"BGP session established"`; L2 undisturbed (DNS `.5` + Traefik `.70` still served).

## Durability
- **Cluster side:** Flux (fully reproducible).
- **UDM side:** UniFi 10.4 stores the BGP config internally and exposes **no usable v2/REST API endpoint** for it (`rest/routing/bgp` + `stat/routing/bgp` return empty; `get/setting`, the device object, and the v2 routing paths don't carry it). So it can't be pushed via an Ansible playbook the way `udm-firewall.yml` / `usw-acls.yml` are. Durability is instead:
  1. **This runbook** holds the exact FRR config — re-upload via the UI on a rebuild.
  2. The config is captured in the **daily UDM controller-config backup** (`unifi-backup` CronJob → S3, M31), so a controller restore brings it back.
- If UniFi later exposes a BGP config API (or one is found), promote this to a `udm-bgp.yml` playbook.

## Next: Phase D (cutover)
Remove the `L2Advertisement` from `metallb-wind.yaml` → BGP becomes the sole advertisement → the `.5`/`.71` ARP/MAC churn stops → **M36 resolved**. Rollback: re-add `L2Advertisement` (instant, VIPs never change IP). Verify the IP-conflict alerts stop after.
