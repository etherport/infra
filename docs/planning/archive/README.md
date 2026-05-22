# Planning Archive

Historical planning docs preserved for context and ADR-style decisions.
Don't link to these from active code — link to the current state in
`docs/planning/outstanding-work.md` or relevant runbook instead.

Active planning lives at `docs/planning/` (top level). When archiving,
add a one-line entry to the table below stating why and where the
current state is documented.

## What's here and why

| File | Why archived | Current state lives in |
|---|---|---|
| `outstanding-work-2026-05-16.md` | Superseded by dated successor. The successor explicitly links forward. | `docs/planning/outstanding-work.md` |
| `doc-drift-2026-05-16.md` | All listed drift items shipped via H7 (✅ 2026-05-19/21). | Architecture docs themselves; H7 entry in canonical tracker |
| `long-term-stability-review-2026-05-12.md` | Post-rebuild RCA. Contains decisions worth preserving; immediate fixes shipped. | Multiple H/M entries in canonical tracker |
| `migration-questions-2026-05-12.md` | Decision log for the K8s HA migration. Migration done; preserving as ADR-adjacent. | `docs/planning/archive/k8s-ha-migration.md` (companion) |
| `production-hardening-review-2026-05-16.md` | Recommendations folded into canonical H/M items. | `docs/planning/outstanding-work.md` |
| `INFRASTRUCTURE-HARDENING-CHECKLIST.md` | Pre-rebuild checklist; remaining items in canonical (D1/D2 explicitly dropped). | `docs/planning/outstanding-work.md` |
| `PRODUCTION-READINESS-CHECKLIST.md` | Same — superseded by canonical (D3 explicitly dropped). | `docs/planning/outstanding-work.md` |
| `aws-cost-analysis.md` | Phase 1 cost picture stale (post-SDN, post-budget alarm). Architecture notes still useful. | Canonical for cost work; `terraform/aws/external-monitoring/budget.tf` for budget alarm |
| `github-actions-automation-roadmap.md` | Most automation shipped (route53, external-monitoring, drift detection). Tail-end items in canonical. | Workflow files themselves; L9 in canonical |
| `proxmox-sdn-migration-2026-05-17.md` | Explicitly superseded by `proxmox-sdn-implementation-2026-05-18.md`. | `docs/planning/proxmox-sdn-implementation-2026-05-18.md` |
| `k8s-ha-migration.md` | Pre-existing — completed migration. | Cluster topology / runbooks |
| `K8S-W3-DEPLOYMENT-PLAN.md` | Pre-existing — completed deployment. | n/a |
| `proxmox-sdn-implementation-2026-05-18.md` | PRs 1-6 all shipped 2026-05-18 to 2026-05-22 (#19 in canonical, ✅). | `docs/planning/outstanding-work.md` H26 + commit history |
| `TODO-configmap-migration-2026-05-22.md` | Migration described already implemented; per-share + global excludes wired via `configMapGenerator` in `platform/kubernetes/backups/aws-s3/{base,shares/*}`. Verified via kubectl kustomize on 2026-05-22. M3 in canonical. | Each share's `kustomization.yaml` + `excludes-share.txt`; `base/excludes-global.txt` |

## Future archive convention

When archiving a new doc:
1. `git mv docs/planning/<name>.md docs/planning/archive/<name>.md`
2. Add a row to the table above with the "why" and "current state lives in" columns filled in.
3. If the doc is a post-mortem or RCA, optionally add a `> **Status:** Archived YYYY-MM-DD — see <link>` banner at the top of the doc itself.
