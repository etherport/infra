# networkpolicies — H3 internal segmentation (Cilium)

Default-deny + per-tier allowlists for the `wind` cluster. Closes H3 (the largest
internal-segmentation gap: today Cilium is allow-all, so a compromised pod has
unrestricted lateral movement). Detailed plan: `docs/planning/hardening-plan-2026-06-10.md` §H3.

> ✅ **ENFORCING since 2026-06-22.** Cilium `policy-audit-mode` is now **OFF** — these
> policies enforce (real drops). Enforced tiers (labeled `netpol.wind/enforced=true`):
> **`postgres`** (tier 1, `10-tier-postgres.yaml`) and **`cue`** (tier 2, `11-tier-cue.yaml`)
> — each allowlist built+verified from Hubble/audit data (0 drops post-flip). **All
> unlabeled namespaces remain allow-all.** Observation phase ran 06-15→06-22 under audit mode.
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

## Phasing model — opt-in per namespace via a label

Enforcement is gated on the namespace label **`netpol.wind/enforced: "true"`**. A
namespace is allow-all until labeled; labeling it makes it default-deny and subject to
the universal allows + its tier allowlist. This gives a clean, reversible, per-namespace
rollout (Phase 2's "postgres → cue → dns → traefik → monitoring" order = label them in
that order). `kube-system`, `flux-system`, `wireguard` (hostNetwork → node identity),
`metallb-system` are **never** labeled.

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
  (postgres now AUDITs nothing): ingress `:5432` from `cnpg-system`/`wikijs`/intra +
  `:8000` from `cnpg-system` (operator→instance-manager) + `:9187` from `monitoring`;
  egress `:5432` intra (CNPG replication) + `:443` to `world` (barman backups to S3).
  cue-api uses its **own** `cue-db` in ns `cue`, NOT this cluster. **Enforce-ready.**

The per-tier allowlists (`1x-tier-*.yaml`) beyond postgres are **intentionally absent**
— they get written from Phase-1 audit data, not guessed.

## Current state (2026-06-22)

Enforcing. `cilium_policy_audit_mode: false`. Enforced tiers:
- **`postgres`** (`10-tier-postgres.yaml`) — verified 0 AUDIT over 7d before the flip;
  post-flip 0 DROPs, CNPG healthy, wikijs path OK, exporters scraping.
- **`cue`** (`11-tier-cue.yaml`) — cue-api + single-instance cue-db; allowlist from live
  Hubble flows + architecture; post-flip 0 DROPs, cue-api serves (HTTP 302), cue-api↔cue-db
  OK, both pods healthy. cloudflared/tailscale ingress + cue-db→S3 barman egress allowlisted.

All other namespaces are unlabeled = allow-all.

> **Monitoring gap:** the audit→Loki pipeline (`CiliumNetpolAuditFlow`) only catches
> `AUDIT` verdicts, which no longer occur once a tier ENFORCES. A wrongly-dropped flow on an
> enforced tier therefore does NOT alert — you find it via the app breaking or a manual
> `hubble observe --verdict DROPPED`. Follow-up (tracked under H3): export `verdict=DROPPED`
> for enforced namespaces → Loki → alert. (CNPG backup failures are still caught separately
> by `CNPGBackupFailed`.)

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
