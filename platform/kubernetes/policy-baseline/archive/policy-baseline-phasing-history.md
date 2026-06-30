# Policy-baseline phasing history (archived)

> 📦 **Historical — completed migrations.** This captures *how the cluster-hardening
> baseline (PSS labels, LimitRanges, ResourceQuotas, NetworkPolicies) got to its current
> shape* — the original 3-phase rollout plan and the dated decisions along the way. It is
> **not** the live reference; for current state see [`../README.md`](../README.md). Kept so
> the rationale and chronology behind the live design are grep-able.

All of the below is **done**. Newest first.

---

## 2026-06-24 — README correction: "Phase 2" was already shipped elsewhere

An earlier revision of the live README still described **Phase 2 (enforced NetworkPolicies)**
as future work ("needs a Hubble observation window first") and listed the tier-1 namespaces
as **HA**, postgres, traefik, dns, monitoring.

Both were stale:

- **Phase 2 was DONE** — but implemented in a **separate** directory, [`../../networkpolicies/`](../../networkpolicies/)
  (Cilium CNPs), not under `policy-baseline/`. All **5 tiers ENFORCING** as of 2026-06-23.
- The enforced tiers are **postgres, cue, dns, traefik, monitoring** — **`cue`, not `HA`**.
  The original plan's "HA" tier was never a NetworkPolicy tier.

See [`../../networkpolicies/README.md`](../../networkpolicies/README.md) +
[`docs/runbooks/networkpolicy-tiers.md`](../../../../docs/runbooks/networkpolicy-tiers.md)
for the live NetworkPolicy state.

## 2026-06-28 — M72 tail: PSS `enforce` reaches baseline-clean infra namespaces

`enforce: baseline` (which *blocks* violating pod creation, vs audit/warn which only
log/surface) was originally **NOT set** in Phase 1 — deferred 1-2 weeks so we could watch
the audit log and identify legitimate privileged workloads first. Over M72 the
baseline-clean `tier=data` namespaces graduated to `enforce: baseline` (2026-06-02), and
the M72 tail (2026-06-28) extended it to the two baseline-clean **infra** namespaces
(`cert-manager`, `cnpg-system`). Namespaces that still run legitimately elevated pods
(`home-automation`, `monitoring`, `tailscale`) stay audit/warn-only; `tier=system`
privileged-by-design namespaces (`plex`, `wireguard`) stay unrestricted. All of those PSS
labels live in [`../../../clusters/wind/namespace-pss-labels.yaml`](../../../../clusters/wind/namespace-pss-labels.yaml),
not in `policy-baseline/`.

## 2026-05-13 — original 3-phase rollout plan (Plan agent)

Designed by the Plan agent run on 2026-05-13. Lineage:
[`docs/planning/archive/long-term-stability-review-2026-05-12.md`](../../../../docs/planning/archive/long-term-stability-review-2026-05-12.md).
The rollout was scoped as three phases:

- **Phase 1** — PSS namespace labels (audit + warn) + default LimitRanges. Landed first in
  `policy-baseline/`. `enforce` was intentionally **not** set at this point.
- **Phase 2** — enforced NetworkPolicies for the tier-1 namespaces (originally listed as
  HA, postgres, traefik, dns, monitoring), to land **after** a Hubble observation window.
  Delivered later in [`../../networkpolicies/`](../../networkpolicies/) (see the 2026-06-24
  correction above — the real tiers were postgres/cue/dns/traefik/monitoring).
- **Phase 3** — ResourceQuotas + PDBs for HPA-scaled workloads. **Object-count
  ResourceQuotas shipped** (M5; `resourcequotas/default-quota.yaml`). **Compute quotas
  (`requests.cpu`/`memory`) + PDBs were deferred** — they need real resource-usage data and
  Helm-managed PDBs across the chart releases.
