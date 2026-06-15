# networkpolicies — H3 internal segmentation (Cilium)

Default-deny + per-tier allowlists for the `wind` cluster. Closes H3 (the largest
internal-segmentation gap: today Cilium is allow-all, so a compromised pod has
unrestricted lateral movement). Detailed plan: `docs/planning/hardening-plan-2026-06-10.md` §H3.

> ⚠️ **THIS DIRECTORY IS NOT YET WIRED INTO FLUX.** It is staged/inert. Applying it
> while `policy-audit-mode: false` would cause an **immediate cluster outage** (see the
> Cilium gotcha below). Do **not** add it to `clusters/wind/kustomization.yaml` until
> audit mode is confirmed active on every node.

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

- `00-default-deny.yaml` — CCNP: default-deny ingress+egress for any pod in a namespace
  labeled `netpol.wind/enforced=true` (via `enableDefaultDeny`, no allow rules of its own).
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

1. **Enable audit mode** (cluster-wide) and **verify** `policy-audit-mode: true` on every
   cilium agent. See `docs/runbooks/` (and the H3 plan) — Cilium is Helm-managed here.
2. Wire this dir into `clusters/wind/kustomization.yaml`; reconcile. Under audit, nothing drops.
3. Observe ≥1–2 weeks: `hubble observe --verdict AUDIT --namespace <ns>` (cover CronJobs).
4. Refine/add `1x-tier-*.yaml` allowlists from the audit data.
5. **Enforce:** label a namespace `netpol.wind/enforced=true` (start postgres), watch
   Hubble for `DROPPED`, widen allowlists as needed, then move to the next tier. Disable
   global audit mode only once all target namespaces are labeled and stable.

## Rollback

`git revert` the wiring commit (Flux `prune: true` deletes the CCNPs in ~1 reconcile),
or re-enable `policy-audit-mode: true` out-of-band, or `kubectl label ns <ns>
netpol.wind/enforced-` to drop a single namespace back to allow-all.
