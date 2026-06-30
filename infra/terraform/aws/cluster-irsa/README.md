# cluster-irsa (M75)

In-cluster workload identity for AWS — the self-hosted (non-EKS) **IRSA** pattern.
In-cluster workloads get short-lived, per-pod AWS creds via
`AssumeRoleWithWebIdentity` instead of long-lived static IAM keys in K8s
Secrets/etcd. Same standing-credential class [[H29]] killed in CI and [[M71]]
targets on the mini — extended **into the cluster**.

This README covers the **Terraform stack** (the AWS-side issuer, provider, and
roles). For the end-to-end design — apiserver issuer config, token projection per
workload, and the operational gotchas — see
[`docs/runbooks/irsa-workload-identity.md`](../../../../docs/runbooks/irsa-workload-identity.md)
(current state); the rollout history is in
[`docs/runbooks/archive/irsa-workload-identity-migration-history.md`](../../../../docs/runbooks/archive/irsa-workload-identity-migration-history.md).

## What it creates

- **Public OIDC discovery bucket** `wind-cluster-oidc-830881980142` (`us-west-2`) —
  holds the only two public-read objects in the account:
  `/.well-known/openid-configuration` and `/keys.json` (the cluster's public SA
  signing keys, copied from `kubectl get --raw /openid/v1/jwks`). Issuer URL =
  `https://wind-cluster-oidc-830881980142.s3.us-west-2.amazonaws.com` (dotless
  bucket → single-label host → valid under the `*.s3.us-west-2.amazonaws.com` cert).
- **IAM OIDC provider** for that issuer URL (thumbprint computed live from the S3
  endpoint cert chain). The kube-apiserver `--service-account-issuer` is set to the
  same URL so pod projected-SA tokens carry `iss=<bucket-url>`.
- **Per-workload roles** (inline least-priv policies), trust locked to the exact
  namespace/ServiceAccount:
  | Role | Trusted SA(s) | Scope |
  |---|---|---|
  | `wind-irsa-velero` | `velero:velero-server` | velero bucket RW |
  | `wind-irsa-s3-sync` | `backups:s3-sync-*`, `backups:unifi-backup`, `backups:daily-report` | archive / logs.archive / archive-test / infra (== `s3-backup-kubernetes-policy.json`) + SES `SendEmail` (daily-report + delete-guard approval mail) |
  | `wind-irsa-barman` | `postgres:postgres-cluster`, `cue:cue-db` | postgres-barman bucket RW |
  | `wind-irsa-cue-media` | `cue:cue-api` | cue-media bucket RW (bug screenshots; workout media next) |
  | `wind-irsa-cloudwatch-read` | `auto-remediation:remediation-controller`, `cloudwatch-to-loki:cloudwatch-to-loki`, `monitoring:service-status-report` | CloudWatch Logs read + SES `SendEmail` (service-status-report/ai-advisor daily email) |

Outputs: `issuer_url`, `oidc_provider_arn`, and `role_arns` (workload → role ARN,
used to wire each workload's `AWS_ROLE_ARN`).

## Apply (CI-only, M82)

Via the `Cluster IRSA Terraform` workflow (`.github/workflows/terraform-cluster-irsa.yml`)
— `workflow_dispatch` → `plan` / `apply`. CI assumes `gh-actions-terraform` (OIDC),
whose scoped IAM policy already permits OIDC-provider + role + policy creation, so
**no admin bootstrap is needed**. PRs auto-plan; pushes to `main` plan; apply is manual.

## Maintenance

- **Re-sync `keys.json` ONLY if the SA signing key (`sa.key`) is rotated** — then
  copy `kubectl get --raw /openid/v1/jwks` over `keys.json` and re-apply.
- Adding a workload: add an entry to `local.roles` in `main.tf` (SA subject + inline
  policy), apply, then wire the workload to assume the role (mount a projected SA
  token with audience `sts.amazonaws.com` + set `AWS_ROLE_ARN` /
  `AWS_WEB_IDENTITY_TOKEN_FILE`) — see the runbook.
