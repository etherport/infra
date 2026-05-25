# Auto-Remediation Setup

The original "first-time setup" steps in this file are obsolete —
the static rule path + the AI advisor + the Alertmanager wiring
are all Flux-managed now. Deployment is:

```bash
# Make a change in platform/kubernetes/auto-remediation/ or in
# platform/kubernetes/monitoring/03-alertmanager-config.yaml
git commit
git push
# Flux reconciles within ~1 min; or force:
kubectl annotate -n flux-system kustomization/flux-system \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
```

For everything else, use the canonical docs:

- **Architecture, files, env vars, RBAC**:
  [`platform/kubernetes/auto-remediation/README.md`](../../../platform/kubernetes/auto-remediation/README.md)
- **Static-rule coverage matrix**:
  [`platform/kubernetes/auto-remediation/COVERAGE.md`](../../../platform/kubernetes/auto-remediation/COVERAGE.md)
- **Enable AI advisor Phase 1 / 2 / 3**: see `../ai-advisor-phase{1,2,3}-enable.md`
- **AWS CloudWatch context**: see `../ai-advisor-phase-b-cloudwatch.md`

## Adding a new static rule (still relevant)

1. Add the PrometheusRule entry to the appropriate file under
   `platform/kubernetes/monitoring/` with `auto_remediate: "true"`.
2. Add the alert→action mapping to
   `platform/kubernetes/auto-remediation/configmap.yaml`.
3. Update
   [`platform/kubernetes/auto-remediation/COVERAGE.md`](../../../platform/kubernetes/auto-remediation/COVERAGE.md)
   to reflect the new coverage.
4. Commit + push.
