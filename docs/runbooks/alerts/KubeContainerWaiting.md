# KubeContainerWaiting

Default kube-prometheus-stack alert. Fires when a container has been
in the `Waiting` state for >1 hour. Severity: warning.

## Symptom

A container in some namespace has been waiting (not running, not
crash-looping — just waiting) for over an hour. Common manifestations:
ImagePullBackOff, CreateContainerConfigError, CreateContainerError,
ContainerCreating that never completes.

## Verified root cause(s)

- ImagePullBackOff: image tag doesn't exist, private registry creds
  missing/rotated, or registry rate-limit hit.
- ConfigMap / Secret referenced by the pod doesn't exist (typo,
  missing SOPS decrypt, Flux failed to apply).
- PVC pending — storage class missing or backend (longhorn / NFS) down.
- Init container that never completes (waiting on a dependency
  service that's also down).
- Node tainted / unschedulable + pod has no matching toleration.

## Fix history

- 2026-05-22 (commit 28c1c2c): General alertmanager tuning noted this
  alert as one of the noise-contributors during incident #37 — but
  the rule itself wasn't modified (it's a kube-prometheus-stack
  default, not a custom rule).
- 2026-05-22 (commit cd208e5): Severity=warning routed to non-email
  destinations via the critical-only email filter.

## Verification steps

1. Find the waiting pod:
   `kubectl get pods -A --field-selector=status.phase=Pending`
   `kubectl get pods -A -o json | jq '.items[] | select(.status.containerStatuses[]?.state.waiting) | .metadata.namespace + "/" + .metadata.name'`
2. Reason for wait:
   `kubectl -n <ns> describe pod <pod>` — look at Events section.
3. Common quick checks:
   - `kubectl -n <ns> get events --sort-by=.lastTimestamp`
   - `kubectl -n <ns> get configmaps,secrets` (to find missing refs)
   - `kubectl get pvc -A | grep -v Bound`
4. After fix, container should progress to Running or get replaced.

## Advisor action guidance

- `delete_evicted_pods` is useful when stuck pods are in `Evicted`
  state (not strictly Waiting, but often diagnosed together).
- `rollout_restart` (Tier 2) is appropriate when a stale ReplicaSet
  is referencing a deleted ConfigMap and a fresh rollout will pick up
  the new one.
- `noop` is correct for ImagePullBackOff on missing/typo'd image tags
  — operator must fix the Deployment manifest.
- Avoid `restart_pods` on pods that have never reached Running — the
  underlying issue (missing secret / image / PVC) will recur.
