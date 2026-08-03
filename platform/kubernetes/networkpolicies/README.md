# networkpolicies — H3 internal segmentation (Cilium)

Default-deny + per-tier allowlists for the `wind` cluster. Closes H3 (the largest
internal-segmentation gap: today Cilium is allow-all, so a compromised pod has
unrestricted lateral movement). Detailed plan: `docs/planning/archive/hardening-plan-2026-06-10.md` §H3.

> ⚠️ **14 TIERS LABELED — ALL 14 ENFORCING (as of 2026-07-28).** Check live before assuming
> either state: `kubectl get cm -n kube-system cilium-config -o
> jsonpath='{.data.policy-audit-mode}'` (`true`=audit-only/no real drops cluster-wide,
> `false`=enforce; confirmed `false` live). Tiers `postgres` (1), `cue` (2), `dns`/Technitium
> (3), `traefik` (4), `monitoring` (5) — the 5 H3 target tiers, enforcing since 2026-06-23 —
> and `authentik` (6, the SSO IdP; M115, added 2026-07-01) were built+verified from
> Hubble/audit data (0 drops). 8 more namespaces were labeled 2026-07-25 (`flux-system`,
> `velero`, `backups`, `tailscale`, `cert-manager`, `garage`, `home-automation`, `plex` —
> tiers 7-14, manifests `17-tier-flux.yaml` through `23-tier-home-automation.yaml` +
> `16-tier-plex.yaml`); their observation window closed and audit-mode was flipped back OFF
> 2026-07-28, so all 14 tiers now enforce together (tracked as M147/M151 in
> `docs/planning/outstanding-work.md`). **Because `policy-audit-mode` is a single GLOBAL
> switch, all 14 will revert to audit-only together if it's flipped ON again to onboard a
> future tier 15.** **All unlabeled namespaces remain allow-all.**
>
> ⚠️ **Audit is a single GLOBAL switch.** To add the NEXT tier you must briefly flip audit
> back ON, observe + build that namespace's allowlist, then flip OFF again — see "Adding a
> tier" below. **Never label a namespace while audit is OFF** unless its allowlist is already
> verified (it would enforce instantly = real drops).

## The one rule that matters

In Cilium an endpoint becomes **default-deny** for a direction the instant *any* policy
with rules in that direction selects it. So an "allow DNS egress" policy on a pod denies
*all that pod's other egress*. This is why **audit mode must be ON before you label a NEW
namespace** (it would otherwise enforce instantly): under audit mode Cilium logs would-be
drops as `AUDIT` verdicts and enforces nothing — the safe observation window to build that
namespace's allowlist from real traffic before flipping back to enforce. See "Adding the
next tier" below.

## ⚠️ The OTHER rule that matters — allow CONTAINER ports, not SERVICE ports

Cilium evaluates ingress policy **at the destination pod**, on the port the packet
actually carries when it arrives there. For traffic via a Kubernetes Service
(ClusterIP **or** LoadBalancer/MetalLB VIP), **kube-proxy DNATs the service port to the
pod's `targetPort` (containerPort) *before* Cilium sees it.** So a tier allowlist must
permit the **container** port, not the service port.

This bit us hard (2026-06-23, ~16h Traefik-VIP outage): the `traefik-tier` ingress
allowed the LoadBalancer service ports `:80/:443` from `world`, but the pod receives
`:8000` (web) / `:8443` (websecure) after DNAT — only `:8088` (webhook) survived because
its service and container ports share the number. `world`→VIP traffic was silently
dropped (`Policy denied … →:8443`) while in-cluster traffic — allowed on `:8443` from
`cluster` — kept working, masking it. Check the mapping before writing a rule:

```bash
kubectl get svc -n <ns> <svc> -o jsonpath='{range .spec.ports[*]}{.name} port={.port} target={.targetPort}{"\n"}{end}'
```

**Debugging a suspected netpol drop on a Service/VIP:** `cilium-dbg monitor --type drop`
and look for the **pod IP + container port** as the destination — NOT the service IP/VIP
(post-DNAT the VIP is gone from the packet). Grepping for the VIP finds nothing.

**Detection (so it can't silently recur):** the `CiliumTraefikIngressDrop` loki-ruler rule
(`platform/kubernetes/monitoring/06-loki-rules-cilium-audit.yaml`) pages **critical** on any
`DROPPED` flow to traefik on a public entrypoint container port (`:8000/:8443/:8088`) — these
must accept `world`, so a drop is always a policy bug. (The general `CiliumNetpolDropFlow`
rule excludes `world` sources as scan noise, which is exactly what hid the 2026-06-23 outage
for 16h.) A `world`-source drop to a *non-traefik* enforced tier still won't auto-alert —
use `hubble observe --verdict DROPPED` for those.

## Phasing model — opt-in per namespace via a label

Enforcement is gated on the namespace label **`netpol.wind/enforced: "true"`**. A
namespace is allow-all until labeled; labeling it makes it default-deny and subject to
the universal allows + its tier allowlist. This gives a clean, reversible, per-namespace
rollout (Phase 2's "postgres → cue → dns → traefik → monitoring" order = label them in
that order). `kube-system`, `wireguard` (hostNetwork → node identity), `metallb-system` are
**never** labeled. (`flux-system` WAS on that never-label list but is labeled as of
2026-07-25 — M151, tier 7; see the banner above.)

## Files

> **No standalone default-deny object.** Cilium's operator rejects an empty-rule policy
> ("rule must have at least one of Ingress/Egress/..."). In Cilium, an endpoint is
> default-deny for a direction the moment it's **selected by any policy with rules in that
> direction** — so the `allow-*` CCNPs below (which select enforced namespaces and together
> cover both ingress and egress) *are* the default-deny. Invariant: keep both directions
> represented across them, or that direction silently reverts to allow-all.

- `01-allow-dns.yaml` — CCNP: those pods may resolve DNS. **Critical:** allows
  `toEntities:[host,remote-node]:53` because pods send DNS to nodelocaldns at the
  link-local `169.254.25.10` (host identity), plus the kube-dns selector as belt-and-braces.
- `02-allow-cluster-essentials.yaml` — CCNP: egress to `kube-apiserver` + host/remote-node
  health comms; ingress from host/remote-node (kubelet probes).
- `03-allow-monitoring-scrape.yaml` — CCNP: ingress from the `monitoring` namespace AND
  from host/remote-node entities (node-exporter/Prometheus pods are hostNetwork here).
- `10-tier-postgres.yaml` — first concrete tier (Phase 2 lead), CNP `postgres-tier`.
  **Allowlist refined 2026-06-22 from audit data** so it covers every observed flow
  (postgres now AUDITs nothing): ingress `:5432` from `cnpg-system`/`wikijs`/`authentik`/intra +
  `:8000` from `cnpg-system` + intra (operator→instance-manager; intra-ns added 2026-07-13
  `949fe59` — CNPG 1.30 instances query each other's instance-manager status API) +
  `:9187` from `monitoring`; egress `:5432`/`:8000` intra (CNPG replication + peer status) +
  `:443` to `world` (barman backups to S3).
  cue-api uses its **own** `cue-db` in ns `cue`, NOT this cluster. **Enforce-ready.**
- `11-tier-cue.yaml`, `12-tier-dns.yaml`, `13-tier-traefik.yaml`, `14-tier-monitoring.yaml`
  — the remaining four H3 tiers (CNP `cue-tier`/`dns-tier`/`traefik-tier`/`monitoring-tier`),
  each allowlist written from that namespace's Phase-1 audit data, not guessed. See
  "Current state" below for the per-tier specifics.
- `15-tier-authentik.yaml` — **tier 6, the SSO IdP** (CNP `authentik-tier`; M115, added
  2026-07-01 via the audit-toggle workflow). Ingress `:9000` (container port; svc `:80` DNATs
  to it) from `traefik` (all logins/OIDC/forward-auth) + `blackbox-exporter` (AuthentikDown
  probe) + intra-ns (worker↔server outpost, redis); egress `postgres` `:5432` + SES SMTP
  `world` `:587` (recovery/invite mail) + intra-ns. Deliberately **no `world` :443** (update
  check/analytics/gravatar all disabled).

## Current state (updated 2026-07-28)

Enforcing. `cilium_policy_audit_mode: false`. Enforced tiers (first 6 built 2026-07-01 or
earlier; tiers 7-14 added below):
- **`postgres`** (`10-tier-postgres.yaml`) — verified 0 AUDIT over 7d before the flip;
  post-flip 0 DROPs, CNPG healthy, wikijs path OK, exporters scraping.
- **`cue`** (`11-tier-cue.yaml`) — cue-api + single-instance cue-db; allowlist from live
  Hubble flows + architecture; post-flip 0 DROPs, cue-api serves (HTTP 302), cue-api↔cue-db
  OK, both pods healthy. cloudflared/tailscale ingress + cue-db→S3 barman egress allowlisted.
- **`dns`/Technitium** (`12-tier-dns.yaml`) — critical resolver, so query ports
  (`:53`/`:853`/`:53443`) use `all`, `:5380` admin uses `cluster` only (VIP:5380 from world
  closed = security improvement), egress `world` for recursion/DoH/DoT + intra-dns. ICMP
  type-3 (port-unreachable) to/from world allowed to silence benign recursion drop-noise.
  Verified post-flip: internal + external + cluster DNS resolution all OK, 3 pods healthy,
  0 dns-pod drops.
- **`traefik`** (`13-tier-traefik.yaml`) — the ingress controller (high-fanout). Done via
  the **audit toggle**: re-enabled audit, applied a permissive-egress draft (`cluster`
  any-port + `world` :80/:443/:8006 so no backend route is ever cut), actively exercised
  the external device routes (UPS/PDU/Proxmox) + internal routes + public ingress → 0 AUDIT
  → flipped audit OFF. Ingress: public entrypoints (:80/:443/:8088) from `all`, mgmt
  (:8080/:8443) in-cluster. Verified post-flip: all routes 200/302/303/404 (working), 0
  drops. (Labelled via `clusters/wind/namespace-pss-labels.yaml` — Helm-created ns.)
- **`monitoring`** (`14-tier-monitoring.yaml`) — the widest-fanout namespace (Prometheus
  scrapes every ns + external hosts; Alloy ingests logs/syslog; AM/ai-advisor egress
  externally). Like traefik, deliberately PERMISSIVE so scraping never cuts: egress
  `cluster` any-port + `world` on enumerated ports (SES :587/:465/:25, APIs :443/:80,
  external node-exporters :9100, pve-IPMI :9290); ingress `cluster` any-port + `world`
  :9091/:3100/:514 (push/logs/syslog) + kube-apiserver (operator webhook). Verified via
  the audit toggle: 0 would-be-drops over 24h incl. periodic paths (391 AM notifications,
  0 failed) → audit OFF. (Labelled via `clusters/wind/namespace-pss-labels.yaml`.)

- **`authentik`** (`15-tier-authentik.yaml`) — **tier 6, the SSO IdP** (M115, added
  2026-07-01 via the audit toggle). Ingress `:9000` from `traefik` (logins/OIDC/forward-auth)
  + `blackbox-exporter` (probe) + intra-ns; egress `postgres` `:5432` + SES `world` `:587` +
  intra-ns (redis). No `world` :443 (update check/analytics/avatars disabled). Validated
  under audit → 0 would-be-drops → audit OFF.

- **tiers 7-14** — `flux-system`, `velero`, `backups`, `tailscale`, `cert-manager`, `garage`,
  `home-automation`, `plex` (M147/M151, labeled 2026-07-25). Built+verified from the
  2026-07-25→2026-07-28 audit observation window, then flipped to enforce with the rest on
  2026-07-28. See `docs/planning/outstanding-work.md` M147/M151 for the per-tier build notes.

All other namespaces are unlabeled = allow-all.

> **DROP alerting is LIVE.** The hubble export now carries both verdicts
> (`hubble-export-allowlist` = `verdict:[AUDIT,DROPPED]`) → Loki `{job="hubble-audit"}` →
> the loki-ruler rules in `platform/kubernetes/monitoring/06-loki-rules-cilium-audit.yaml`:
> `CiliumNetpolDropFlow` (a real DROP to/from an enforced tier) +
> `CiliumTraefikIngressDrop` (critical — a DROP on a Traefik public entrypoint container
> port). So a wrongly-dropped flow on an enforced tier now alerts in ~10m instead of staying
> silent until the app breaks. **Remaining gap:** `CiliumNetpolDropFlow` excludes `world`
> sources (scan noise), so a wrongly-dropped EXTERNAL client to a *non-traefik* enforced tier
> still won't auto-alert — find those with `hubble observe --verdict DROPPED`. (CNPG backup
> failures are still caught separately by `CNPGBackupFailed`.)

## ⚠️ Adding or changing a service (operational tax)

Enforcement means **new services that cross an enforced boundary must be allowlisted or
they silently break.** Three cases: (1) a new workload IN an enforced ns; (2) a new
workload anywhere that must REACH an enforced ns (e.g. a new app using the shared
`postgres`); (3) a new EXTERNAL backend for Traefik. Full procedure + how to detect the
drop (`hubble observe --verdict DROPPED`) + the fix workflow:
**[`docs/runbooks/networkpolicy-tiers.md`](../../../docs/runbooks/networkpolicy-tiers.md)**.
Rule of thumb: if the change crosses an enforced namespace boundary, update that tier's
`1x-tier-<ns>.yaml` in the same change. Unlabelled↔unlabelled needs nothing.

## Adding the next tier (the toggle workflow)

Because audit is a **single global switch**, you can't observe a new namespace while the
rest enforce. So:

1. **Flip audit back ON** (live, no kubespray): `kubectl -n kube-system patch cm cilium-config
   --type merge -p '{"data":{"policy-audit-mode":"true"}}'` + `kubectl -n kube-system rollout
   restart ds/cilium`. Set `cilium_policy_audit_mode: true` in the kubespray inventory too
   (durability). While ON, the already-enforced tiers (postgres) revert to audit-only — fine,
   their allowlists are verified.
2. **Label the new namespace** by editing its namespace MANIFEST in git —
   `netpol.wind/enforced: "true"` (e.g. `platform/kubernetes/cnpg/00-namespace.yaml`). **Do
   NOT `kubectl label`** a Flux-managed namespace — Flux strips out-of-band labels on
   reconcile. Commit + reconcile → durable.
3. **Observe** (days). AUDIT flows ship to Loki: `{job="hubble-audit"}` → the loki-ruler
   `CiliumNetpolAuditFlow` alert (new tuples only). Triage via the alert + Grafana Explore
   (`{job="hubble-audit"} | json`); `python3 scripts/cilium/audit-report.py` is an ad-hoc
   one-shot. Cover CronJobs/backups. Every AUDIT flow = a would-be drop on enforcement.
4. **Write `1x-tier-<ns>.yaml`** from the audit data (both directions — see the postgres tier
   for the pattern: intra-ns egress, external `:443`, operator ports, etc.) until the
   namespace AUDITs nothing.
5. **Flip audit back OFF** (reverse of step 1; inventory back to `false`) → the new tier
   enforces alongside postgres. Re-verify (0 DROPs, app healthy).

## Rollback

`git revert` the wiring commit (Flux `prune: true` deletes the CCNPs in ~1 reconcile), or
remove the `netpol.wind/enforced` label from a namespace manifest (Flux reverts it to
allow-all), or re-confirm `policy-audit-mode` is on (the safe, non-enforcing state).
