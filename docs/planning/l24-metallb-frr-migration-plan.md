# L24 — MetalLB native→FRR migration + BGP TCP-MD5 auth (plan)

**Status:** ✅ **DONE 2026-06-28** — executed in one window (operator at the UDM). All 4 phases
landed: native→FRR migration (seamless flap — L2 net + pre-pulled frr image), TCP-MD5 (proven via
the drop-while-one-sided→re-establish-when-matched behavior), L2 net removed, `metallb_bgp_session_up`
PodMonitor + `MetallbBGP{AllSessionsDown,SessionDown}` alerts. 8/8 Established w/ MD5. Outstanding-work
L24 has the commit list. ⏳ Optional FRR upsides NOT done: graceful-restart + BFD (need UDM-side too);
+ a VLAN-201→VIP `/32 via .1` route so TS/WG remote clients can reach the BGP VIPs.
**Effort (actual):** ~one focused window. Original tracking LOW/S was wrong; it was a backend migration.

**Goal:** authenticate the single MetalLB↔UDM eBGP session with **TCP-MD5** (defense-in-depth
vs a rogue host on VLAN 201 injecting routes) — *and*, since it requires moving MetalLB to FRR
mode anyway, bank the **resilience upside that mode unlocks**: BGP **graceful-restart** + **BFD**
(eliminates the VIP-blackhole-on-speaker-restart risk that exists in native mode today).

---

## Why it's blocked on a migration (the core finding)

*(Pre-migration state — now superseded; see header. Retained as the design record.)*

- **MetalLB runs in NATIVE BGP mode** (v0.14.8, gobgp speaker, single container, no FRR sidecar).
  **Native mode does not implement TCP-MD5** — the `BGPPeer.spec.password`/`passwordSecret` fields
  exist but are **honored only in FRR / frr-k8s mode**. (Refs: MetalLB #1125 `setsockopt protocol
  not available`; Go 1.24 MPTCP lacks `TCP_MD5SIG`.) Setting the password on the cluster side is a
  silent no-op; setting it on the UDM alone **breaks the handshake → all VIPs blackhole**.
- **MetalLB is installed by the kubespray addon** (`metallb_enabled: true` in
  `infra/kubespray/inventory/group_vars/k8s_cluster/addons.yml`), **not** Helm/Flux — only the CRs
  (BGPPeer/IPAddressPool/BGPAdvertisement) are Flux-managed in
  `platform/kubernetes/metallb/metallb-wind.yaml`. **kubespray's metallb role exposes NO FRR
  toggle** (native-only template; its default is even older, v0.13.9). So FRR mode = **migrate
  MetalLB off the kubespray addon onto the official MetalLB Helm chart** (FRR-enabled), managed via
  Flux HelmRelease — the same pattern Cilium already uses. This is a sensible modernization (native
  is legacy; frr-k8s is MetalLB's default backend going forward).

## Blast radius (what a flap costs)

One eBGP session (cluster ASN **64513** ↔ UDM `Windroute` ASN **64512** @ **10.10.201.1**) carries
**every LB VIP** as a /32 (pool `primary`, BGPAdvertisement `primary-bgp` aggLen 32):
`10.10.201.70` **Traefik** (all internal+external ingress, webhook :8088, CF tunnel origin),
`10.10.201.5/.71/.72` **Technitium DNS** (split-horizon for `*.wind.etherport.net`),
`10.10.201.73` alloy-syslog. **No graceful-restart, no BFD, no L2 fallback** (removed Phase D
2026-05-31). On a flap the UDM holds routes until the **180 s** hold timer, then withdraws →
**ingress AND internal DNS blackhole together** (triage is hard — names won't resolve). The outage
is **silent**: `CiliumTraefikIngressDrop` can't fire (no packets reach the pod). The operator/devbox
is NOT self-locked-out (kubectl/SSH + the kube-apiserver `controlPlaneEndpoint` = cp1 `10.10.201.50`
direct, not a VIP) — only *users* of the VIPs see it.

## Mitigations baked into the plan

- **Temporary L2 safety net:** re-add an `L2Advertisement` for pool `primary` BEFORE the migration
  so that if BGP drops, the VIPs stay reachable via L2/ARP (cushions every flap window). Remove it
  at the end (back to BGP-only, now with GR/BFD).
- **Maintenance window** for each flap step; **char-for-char** MD5 secret on both ends.
- **Verify MD5 actually protects**, not just "Established" — FRR #6921: a one-sided password can show
  UP. Confirm with `tcpdump -ni <if> tcp port 179` (MD5 option present) on both ends.
- **Close the silent-outage gap:** add a Prometheus alert on `metallb_bgp_session_up == 0` and/or a
  blackbox TCP probe of the Traefik VIP, since the existing ingress alert won't catch a BGP withdrawal.

---

## Phased plan

**Phase 0 — prep (no traffic impact).**
- Decide backend: **`speaker.frr.enabled=true`** (FRR sidecar in the speaker pod, simplest) vs
  **frr-k8s** (separate DaemonSet, MetalLB's strategic default). Recommend starting with
  `speaker.frr.enabled=true` (fewer moving parts; same MD5/GR/BFD support).
- Author the **Flux HelmRelease** for MetalLB (`clusters/wind/helm-releases/metallb.yaml`, chart
  `metallb/metallb`, pin a current version ≥ live 0.14.8) with FRR mode + values matching today
  (namespace, node selectors/tolerations). Keep the existing Flux CRs as-is (compatible).
- Set `metallb_enabled: false` in kubespray addons.yml **with a comment** that MetalLB is now
  Helm/Flux-managed (so a future kubespray run doesn't re-apply the native addon and fight). NB:
  kubespray won't uninstall the running addon — the Helm release will adopt/replace it.
- `kubectl kustomize` + `helm template` dry-run; confirm zero CR drift.

**Phase 1 — L2 safety net (windowed-lite).** Add `L2Advertisement` for pool `primary` (Flux),
reconcile, verify VIPs answer ARP (so a subsequent BGP flap is cushioned). Low risk (additive).

**Phase 2 — flip to FRR mode (FLAP window #1).** Apply the Helm-managed FRR-mode MetalLB (replaces
the native speaker with speaker+FRR). Speakers restart → all 8 BGP sessions re-establish in FRR mode
(L2 net covers the gap). **Enable graceful-restart + BFD** on the BGPPeer while here. Verify: all
sessions Established (FRR), routes re-advertised, every VIP reachable, `metallb_bgp_session_up==1`.

**Phase 3 — add TCP-MD5 (FLAP window #2).** Create a SOPS-encrypted `kubernetes.io/basic-auth`
Secret `bgp-md5` in `metallb-system` (key `password`); set `spec.passwordSecret: {name: bgp-md5}` on
the `udm` BGPPeer (Flux; **never** plaintext `spec.password` — pre-commit gate). In the SAME window,
on the UDM UI (Settings → Routing → BGP, config `metallb` on `Windroute`) add
`neighbor metallb password <SECRET>` inside `router bgp 64512`. Both ends close together. Verify:
Established **and** MD5 present via `tcpdump tcp port 179` on both ends (not just state).

**Phase 4 — cleanup + docs.** Remove the temporary `L2Advertisement` (BGP-only again, now with
GR/BFD/MD5 → flaps are no longer instant-blackhole). Mirror the new UDM FRR block (with the
`neighbor metallb password` line) into the source-of-truth runbook
`docs/runbooks/archive/bgp-phase-c-udm-metallb.md` so a rebuild re-uploads it. Update
`platform/kubernetes/metallb/README.md` + CLAUDE.md (MetalLB now Helm/Flux + FRR mode). Add the
`metallb_bgp_session_up` alert. Flip L24 ✅ in outstanding-work; session-log entry.

## Rollback (per window)
- Phase 2 fails to re-establish → revert the HelmRelease to native (or re-enable the kubespray
  addon); L2 net keeps VIPs up meanwhile.
- Phase 3 MD5 mismatch (sessions Idle/Connect, `session_up==0`) → **remove the password on BOTH
  ends** (BGPPeer secret ref + the UDM `neighbor … password` line). Fastest recovery is symmetric
  removal; L2 net cushions until BGP returns.

## Open items to confirm during Phase 0
- Why live is v0.14.8 vs kubespray default 0.13.9 (was metallb_version overridden, or hand-upgraded?).
- UDM/UniFi FRR build accepts a **peer-group password on a listen-range** (all 8 dynamic neighbors at
  once — no per-node canary). Confirm in a low-traffic test.
- frr-k8s vs speaker-embedded-FRR final choice.
