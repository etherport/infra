# Policy Baseline — PSS labels + LimitRanges + object-count quotas

> **Update 2026-06-24:** This directory is still just Phase 1 (PSS audit/warn + LimitRanges).
> But **Phase 2 — enforced NetworkPolicies — is DONE**, implemented separately in
> [`../networkpolicies/`](../networkpolicies/) (Cilium CNPs; **all 5 tiers ENFORCING**:
> postgres, **cue**, dns, traefik, monitoring — note: cue, not the "HA" originally listed
> below). See [`../networkpolicies/README.md`](../networkpolicies/README.md) +
> [`docs/runbooks/networkpolicy-tiers.md`](../../../docs/runbooks/networkpolicy-tiers.md).
> The "Phase 2 … needs a Hubble observation window first" text below is historical.

Cluster hardening primitives: namespace labels (Pod Security Standards),
LimitRanges (defaults for pods without explicit requests), and object-count
ResourceQuotas (M5 runaway guardrails). PSS started observation-only
(audit + warn), but as of M72 several baseline-clean namespaces now carry
`enforce: baseline` too — those labels live in
[`../../../clusters/wind/namespace-pss-labels.yaml`](../../../clusters/wind/namespace-pss-labels.yaml),
not this directory. The LimitRanges and ResourceQuotas remain low-risk
(they only fill in / cap, never override explicit specs).

Designed by the Plan agent run on 2026-05-13. The full 3-phase rollout
lives in `docs/planning/long-term-stability-review-2026-05-12.md`:

- **Phase 1 (this directory)** — PSS labels + LimitRanges. Land now.
- Phase 2 — enforced NetworkPolicies for tier-1 namespaces (HA, postgres,
  traefik, dns, monitoring). Needs Hubble observation window first.
- Phase 3 — ResourceQuotas + PDBs for HPA-scaled workloads. **Object-count
  ResourceQuotas shipped** (M5; `resourcequotas/default-quota.yaml`, wired in
  here). **Compute quotas (requests.cpu/memory) + PDBs still deferred** — they
  need resource-usage data + Helm-managed PDBs across the chart releases.

## Directory layout

```
policy-baseline/
├── README.md                          # this file
├── kustomization.yaml                 # aggregator
├── limitranges/
│   └── default-limits.yaml            # default container requests/limits
└── resourcequotas/
    └── default-quota.yaml             # object-count guardrails per ns (M5)

# NB: PSS namespace labels are NOT here — they live in
# ../../../clusters/wind/namespace-pss-labels.yaml (applied via that
# kustomization's patches:, so they can target Helm-created namespaces).
```

## What the labels do

`pod-security.kubernetes.io/{audit,warn}: baseline` on a namespace:

- **audit**: log a Kubernetes audit event whenever a pod is created
  that violates the `baseline` PSS profile (privileged, hostNetwork
  without justification, etc.). Visible via the audit log policy
  enabled by kubespray.
- **warn**: surface the same violations as `kubectl apply` warnings.
  Developers see them when they push manifests.
- **enforce**: NOT set in Phase 1. Adding this would *block* the pod
  creation. Deferred until we've watched the audit log for 1-2 weeks
  to identify legitimate privileged workloads.

## Known legitimate privileged workloads

Don't include these in `baseline`/`restricted` enforcement when we
graduate to Phase 2:

| Namespace | Why privileged |
|---|---|
| `home-automation` | HA needs USB Z-Wave/Zigbee + privileged for some integrations |
| `wireguard` | hostNetwork + NET_ADMIN for tunnel interfaces |
| `gpu-operator-system` | NVIDIA driver pod needs full host access |
| `multus-system` | macvlan secondary networks need NET_ADMIN |
| `metallb-system` | speaker needs hostNetwork for L2 announcements |
| `kube-system` | system controllers (kube-proxy, etc.) |
| `ceph-csi` | rbd device mounts on host |

PSS labelling (including the `tier:` labels used to separate infra from
tenant namespaces) lives in
[`../../../clusters/wind/namespace-pss-labels.yaml`](../../../clusters/wind/namespace-pss-labels.yaml),
not this directory — `tier: system` is set there on the privileged-by-design
infra namespaces (e.g. `wireguard`, `plex`).

## What the LimitRanges do

Set DEFAULT container requests + limits for any pod that doesn't
declare its own. Safe — only fills in missing values; doesn't override
explicit specs. Prevents unbounded resource consumption from a
misconfigured workload.

Defaults are conservative: 100m CPU / 128Mi memory requests, 1 CPU /
1Gi limits. Workloads with explicit requests (postgres, plex, etc.)
keep their own.

## How to verify after rollout

```bash
# Audit log entries for PSS violations (last hour)
kubectl get events --all-namespaces \
  --field-selector reason=FailedCreate,reason=Forbidden \
  --sort-by=.lastTimestamp

# LimitRange in effect
kubectl describe limitrange -n <namespace>

# Pod after creation: did it get defaulted requests?
kubectl get pod <pod> -o jsonpath='{.spec.containers[*].resources}'
```
