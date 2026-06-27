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
| `hardening-plan-2026-06-10.md` | Detailed exec plans for H3 + H29–H34 — all ✅ done. ADR record of how the HIGH items were planned. | `docs/planning/outstanding-work.md` H3, H29–H34 |
| `aws-iam-review-2026-06-11.md` | H31 `claude-admin` redesign + IAM audit — applied (H31 ✅), audit done (M97 ✅). Apply-bundle/audit-script retain reference value. | `docs/planning/outstanding-work.md` H31, M97 |
| `cloudflare-provider-v5-migration.md` | M69 CF provider v4→v5 — ✅ applied + verified 2026-06-13 (PR #66). Migration mechanics preserved. | `docs/planning/outstanding-work.md` M69 / Next-up #6 |
| `gcp-oidc-wif-l21.md` | L21 GCP→Workload Identity Federation — ✅ done 2026-06-13. | `docs/planning/outstanding-work.md` L21 |
| `udm-audit-2026-05-23.md` | One-shot read-only UDM/UniFi config-vs-docs audit; findings drove M30/M52/M56 (all ✅). 884-line historical snapshot. | `docs/architecture/firewall-zones.md` (live zone state) |
| `completed-2026-H1.md` | Full detail for ✅-done tracker items (H3/H29–H40, M-tier, L-tier), extracted 2026-06-24 to slim the live tracker. The tracker keeps a one-line ✅ header per item linking here. | `docs/planning/outstanding-work.md` (one-line ✅ headers) |
| `m76-ssh-shortlived-plan.md` | step-ca SSH-CA hybrid — ✅ cutover DONE 2026-06-26, fleet SSH is cert-only. Design record. | `CLAUDE.md` §4 (live invariant); `outstanding-work.md` M76 |
| `VERSIONING-STRATEGY.md` | Considered-and-declined ADR; repo uses the Flux `$imagepolicy` + digest-pin model, not semver tags. | `outstanding-work.md` M64/H30; `docs/runbooks/image-pinning-policy.md` |
| `kubespray-addons-migration-2026-01-completed.md` | Kubespray addon/config migration — completed early 2026 (moved out of `infra/ansible/`). | Live cluster (3-CP-HA build); `infra/kubespray/` |
| `zero-trust-assessment-2026-06-17.md` | Posture assessment — its 8 gaps (H37/H38/M72–M76/L24) all became tracked items; H37/H38/M75/M76 ✅ shipped, M72/M73/M74 deployed, L24/M71 carried in the tracker. | `docs/planning/outstanding-work.md` (the tracked IDs) |

## Future archive convention

When archiving a new doc:
1. `git mv docs/planning/<name>.md docs/planning/archive/<name>.md`
2. Add a row to the table above with the "why" and "current state lives in" columns filled in.
3. If the doc is a post-mortem or RCA, optionally add a `> **Status:** Archived YYYY-MM-DD — see <link>` banner at the top of the doc itself.
