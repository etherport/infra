# networkpolicies — H3 internal segmentation (Cilium)

Default-deny + per-tier allowlists for the `wind` cluster. Closes H3 (the largest
internal-segmentation gap: today Cilium is allow-all, so a compromised pod has
unrestricted lateral movement). Detailed plan: `docs/planning/hardening-plan-2026-06-10.md` §H3.

> ✅ **WIRED INTO FLUX 2026-06-15** (`clusters/wind/kustomization.yaml`), with Cilium
> **`policy-audit-mode` ON** (verified runtime `Enabled` on all agents first). Under audit
> mode these policies **log would-be drops as AUDIT verdicts and enforce nothing**, so they
> are safe. They also currently select **no pods** — enforcement is gated on the
> `netpol.wind/enforced=true` namespace label (none applied yet). Labeling a namespace is
> what starts its observation. **Never disable audit mode while a namespace is labeled until
> its allowlist is verified** (that would turn audit logs into real drops).

## The one rule that matters

In Cilium an endpoint becomes **default-deny** for a direction the instant *any* policy
with rules in that direction selects it. So an "allow DNS egress" policy on a pod denies
*all that pod's other egress*. **Audit mode must be ON before any of these apply.** Under
audit mode Cilium logs would-be drops as `AUDIT` verdicts and enforces nothing — that's
the safe observation window to build allowlists from real traffic.

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
- `10-tier-postgres.yaml` — first concrete tier (Phase 2 lead): only `cnpg-system`
  (operator) + `wikijs` + `monitoring` may reach the shared postgres `:5432`/`:9187`.
  cue-api uses its **own** `cue-db` in ns `cue`, NOT this cluster.

The per-tier allowlists (`1x-tier-*.yaml`) beyond postgres are **intentionally absent**
— they get written from Phase-1 audit data, not guessed.

## Rollout procedure

1. **Audit mode is ON** (`cilium_policy_audit_mode: true`, runtime `Enabled` on all agents).
2. This dir is wired into `clusters/wind/kustomization.yaml` (done).
3. **Opt a namespace into observation by adding the label to its namespace MANIFEST in git**
   — `netpol.wind/enforced: "true"` (e.g. `platform/kubernetes/cnpg/00-namespace.yaml` for
   postgres). **Do NOT `kubectl label`** a Flux-managed namespace — Flux's server-side apply
   strips out-of-band labels on the next reconcile. Commit + reconcile → durable.
4. Observe ≥1–2 weeks: `python3 scripts/cilium/audit-report.py` (cluster-wide AUDIT flows
   via the hubble relay) — be sure to cover CronJobs/backups. Every AUDIT flow = a would-be
   drop on enforcement.
5. Add legit flows to the relevant per-tier CNP; write `1x-tier-*.yaml` for new tiers from
   the audit data.
6. **Enforce:** once all target namespaces' allowlists are verified, disable global audit
   (`cilium_policy_audit_mode: false` → ConfigMap + `rollout restart ds/cilium`). Audit is
   cluster-wide, so enforce all observed tiers together once they're all clean.

## Rollback

`git revert` the wiring commit (Flux `prune: true` deletes the CCNPs in ~1 reconcile), or
remove the `netpol.wind/enforced` label from a namespace manifest (Flux reverts it to
allow-all), or re-confirm `policy-audit-mode` is on (the safe, non-enforcing state).
