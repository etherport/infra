# Policy Baseline — LimitRanges + object-count ResourceQuotas

Cluster-hardening primitives that fill in / cap resource usage on tenant
namespaces. This directory owns two **low-risk** admission guardrails:

- **LimitRanges** (`limitranges/default-limits.yaml`) — default container
  requests + limits for pods that don't declare their own.
- **ResourceQuotas** (`resourcequotas/default-quota.yaml`) — per-namespace
  object-count caps (M5 runaway guardrails).

Both only fill in missing values or cap counts; **neither ever overrides an
explicit spec**, so they're safe to apply broadly.

> **PSS namespace labels are NOT here.** Pod Security Standards labels
> (`pod-security.kubernetes.io/{audit,warn,enforce}`, plus the `tier:` labels)
> live in
> [`../../../clusters/wind/namespace-pss-labels.yaml`](../../../clusters/wind/namespace-pss-labels.yaml).
> They're applied from `clusters/wind/kustomization.yaml` via `patches:` so they
> can target namespaces created by sibling kustomizations (HelmReleases). See
> "What the labels do" below for the behaviour.
>
> **NetworkPolicies are NOT here either** — the per-tier Cilium segmentation
> lives in [`../networkpolicies/`](../networkpolicies/) (all 5 tiers enforcing).

## Directory layout

```
policy-baseline/
├── README.md                          # this file
├── kustomization.yaml                 # aggregator (LimitRanges + ResourceQuotas)
├── limitranges/
│   └── default-limits.yaml            # default container requests/limits
├── resourcequotas/
│   └── default-quota.yaml             # object-count guardrails per ns (M5)
└── archive/
    └── policy-baseline-phasing-history.md   # how the rollout got here

# NB: PSS namespace labels are NOT here — they live in
# ../../../clusters/wind/namespace-pss-labels.yaml (applied via that
# kustomization's patches:, so they can target Helm-created namespaces).
```

## What the LimitRanges do

Set DEFAULT container requests + limits for any pod in a tenant namespace that
doesn't declare its own. Safe — only fills in missing values; doesn't override
explicit specs. Prevents unbounded resource consumption from a misconfigured
workload.

Defaults are deliberately conservative ("don't accidentally eat the whole
node"). Most namespaces get **100m CPU / 128Mi memory** requests and **1 CPU /
1Gi** limits; `ollama` is higher (100m/256Mi → 2 CPU/4Gi) and `tailscale` is
lower (50m/64Mi → 500m/512Mi). Workloads with explicit requests (postgres, plex,
etc.) keep their own.

Applied to data-tier namespaces only — `home-automation`, `monitoring`,
`postgres`, `traefik`, `dns`, `wikijs`, `ollama`, `backups`, `tailscale`.
`tier=system` namespaces (plex, wireguard, kube-system, etc.) are excluded
because legitimate workloads there often need higher limits.

## What the ResourceQuotas do (M5)

Per-namespace **object-count** caps applied to the same tenant namespaces as the
LimitRanges. Deliberately count-only (`count/pods`, `count/services`,
`count/persistentvolumeclaims`, `count/replicationcontrollers`,
`count/jobs.batch`) — **no `requests.cpu`/`memory` compute quota**: a compute
quota would force every pod to declare requests and risks rejecting mis-sized
workloads, and right-sizing it per namespace needs real usage data. The counts
are generously above current usage, so they never interfere with normal
operation but cap a runaway (a controller spawning thousands of pods/PVCs).

## What the PSS labels do

`pod-security.kubernetes.io/{audit,warn,enforce}` on a namespace (set in
[`../../../clusters/wind/namespace-pss-labels.yaml`](../../../clusters/wind/namespace-pss-labels.yaml)):

- **audit**: log a Kubernetes audit event whenever a pod is created that
  violates the `baseline` PSS profile (privileged, hostNetwork without
  justification, etc.). Visible via the audit log policy enabled by kubespray.
- **warn**: surface the same violations as `kubectl apply` warnings — developers
  see them when they push manifests.
- **enforce**: **blocks** the pod creation. Set to `baseline` on the
  baseline-clean tenant namespaces and the two baseline-clean infra namespaces
  (`cert-manager`, `cnpg-system`). Namespaces that run legitimately elevated pods
  stay audit/warn-only (see the table below).

The `tier:` labels separate infra from tenant namespaces: `tier=data` =
tenant application namespaces, `tier=system` = cluster infrastructure (privileged
workloads expected — e.g. `wireguard`, `plex`).

## Known legitimate privileged workloads

These namespaces run pods that the `baseline` PSS profile would block, so they
are **not** under `enforce` (they stay audit/warn, or `tier=system`
unrestricted):

| Namespace | Why privileged |
|---|---|
| `home-automation` | HA needs USB Z-Wave/Zigbee + privileged for some integrations |
| `monitoring` | node-exporter (hostNetwork/PID), alloy (hostPath), grafana |
| `tailscale` | operator/proxy pods need NET_ADMIN |
| `wireguard` | hostNetwork + NET_ADMIN for tunnel interfaces |
| `plex` | GPU passthrough needs privileged |
| `gpu-operator-system` | NVIDIA driver pod needs full host access |
| `multus-system` | macvlan secondary networks need NET_ADMIN |
| `metallb-system` | speaker needs hostNetwork for L2 announcements |
| `kube-system` | system controllers (kube-proxy, etc.) |
| `ceph-csi` | rbd device mounts on host |

## How to verify

```bash
# Audit log entries / admission rejections for PSS violations
kubectl get events --all-namespaces \
  --field-selector reason=FailedCreate,reason=Forbidden \
  --sort-by=.lastTimestamp

# LimitRange in effect
kubectl describe limitrange -n <namespace>

# Pod after creation: did it get defaulted requests?
kubectl get pod <pod> -o jsonpath='{.spec.containers[*].resources}'

# ResourceQuota usage vs caps
kubectl describe resourcequota -n <namespace>

# Confirm PSS enforce label on a namespace
kubectl get ns <namespace> -o jsonpath='{.metadata.labels}'
```

## Migration history

The original 3-phase rollout (Phase 1 PSS labels + LimitRanges · Phase 2
NetworkPolicies · Phase 3 ResourceQuotas/PDBs), the 2026-05-12 stability-review
lineage, and the dated decisions (deferred `enforce`, the 2026-06-24 README
correction) are archived in
[`archive/policy-baseline-phasing-history.md`](archive/policy-baseline-phasing-history.md).
Phase-2 NetworkPolicies live in [`../networkpolicies/`](../networkpolicies/).
