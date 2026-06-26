# Auto-Remediation Coverage

This document has moved. Canonical coverage matrix lives with the
code, kept in sync with `configmap.yaml`:

**[`platform/kubernetes/auto-remediation/COVERAGE.md`](../../../platform/kubernetes/auto-remediation/COVERAGE.md)**

That file enumerates:
- All 22 static rules (alert → action mapping + selector)
- Coverage gaps (CNPG operator, ceph-csi-rbdplugin-provisioner, WG
  K8s pod, MetalLB speakers, Multus DS)
- Per-rule cooldown semantics + safety guardrails

For the AI advisor layer (which sits behind the same webhook and
handles alerts that don't match static rules), see
[`platform/kubernetes/auto-remediation/README.md`](../../../platform/kubernetes/auto-remediation/README.md)
and the per-phase enable runbooks in `docs/runbooks/archive/ai-advisor-phase*`.
