# kyverno — admission-policy guardrails (M73)

Cluster-wide **admission policy engine**. The *engine* is a Flux HelmRelease
([`clusters/wind/helm-releases/kyverno.yaml`](../../../clusters/wind/helm-releases/kyverno.yaml),
chart 3.8.x / Kyverno v1.18); this directory holds the **ClusterPolicies**.

## Safety model (why this can't wedge the cluster)

1. **Audit-first, enforce-when-clean.** A rule sets `validate.failureAction: Audit` →
   violations are *reported* (PolicyReports), never blocked; flip to `Enforce` only once its
   report is clean. **Current:** `disallow-latest-tag` = **Enforce** (0 violations, 2026-06-27);
   `require-resource-requests` = **Audit** (third-party Helm charts + dynamically-created pods
   lack requests — see its header for the enforce prereq).
2. **Fail-open.** `spec.webhookConfiguration.failurePolicy: Ignore` → if the admission
   controller is down/slow, admission proceeds without the policy (never blocks).
3. **Control-plane excluded.** Policies `exclude` `kube-system`/`flux-system`/`kyverno`
   (+ operator namespaces) so Kyverno can never block the control plane or its own GitOps.

> Division of labour: **PSA** (M72) owns pod-security posture (privileged/host/root).
> **Kyverno** owns the guardrails PSA can't express — resource requests, image tags, and
> (next) image signature/provenance to back H30.

## Policies

| File | Policy | Mode | What it flags | Notable excludes |
|---|---|---|---|---|
| `00-require-resource-requests.yaml` | `require-resource-requests` | **Audit** | containers without cpu+memory requests | system + operator ns |
| `01-disallow-latest-tag.yaml` | `disallow-latest-tag` | **Enforce** | untagged images + `:latest` | system + operator ns, **`cue`** (intentional `:latest`, H30/M64) |

## Operating

- See what's failing: `kubectl get policyreport -A` / `kubectl get clusterpolicyreport`
  (or `kubectl get polr -A`). Drill in: `kubectl describe polr -n <ns>`.
- **Promote a rule to enforce:** once its report is clean for the target namespaces, change
  that rule's `validate.failureAction: Audit` → `Enforce` (consider keeping `failurePolicy:
  Ignore` until you're confident). Commit; Flux applies.
- **Add a policy:** drop a `ClusterPolicy` here (audit-first), add it to `kustomization.yaml`.
- **Ordering note:** these depend on the Kyverno CRDs (from the HelmRelease). On a fresh
  cluster rebuild Flux may transiently error until the engine installs the CRDs, then
  reconciles clean — no action needed.
