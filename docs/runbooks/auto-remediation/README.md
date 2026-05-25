# Auto-Remediation System Runbooks

The canonical docs for the auto-remediation + AI advisor system now
live with the code:

- **Architecture + flow**:
  [`platform/kubernetes/auto-remediation/README.md`](../../../platform/kubernetes/auto-remediation/README.md)
- **Coverage matrix** (what static rules + the advisor cover, where
  the gaps are):
  [`platform/kubernetes/auto-remediation/COVERAGE.md`](../../../platform/kubernetes/auto-remediation/COVERAGE.md)

Phase-enablement runbooks live one level up in `docs/runbooks/`:

- [`ai-advisor-phase1-enable.md`](../ai-advisor-phase1-enable.md) —
  advisory-only diagnosis email path
- [`ai-advisor-phase2-enable.md`](../ai-advisor-phase2-enable.md) —
  approve-via-email (HMAC-signed buttons)
- [`ai-advisor-phase3-enable.md`](../ai-advisor-phase3-enable.md) —
  opt-in autonomous execute (`ai_remediation: "auto"` label)
- [`ai-advisor-phase-b-cloudwatch.md`](../ai-advisor-phase-b-cloudwatch.md) —
  M45 Phase B (AWS CloudWatch log context for AWS-side alerts)

Design spec:
[`docs/planning/ai-alert-remediation-2026-05-23.md`](../../planning/ai-alert-remediation-2026-05-23.md).

The legacy `SETUP.md` / `COVERAGE.md` in this directory pre-date the
M41/M45 expansion and are kept only as thin pointers to the
canonical files above. Do not edit them — edit the platform docs
and update this README if structure changes.
