# cluster-irsa (M75)

In-cluster workload identity for AWS — the self-hosted (non-EKS) **IRSA** pattern.
Replaces the long-lived static IAM keys that in-cluster workloads carry in K8s
Secrets/etcd with short-lived, per-pod creds via `AssumeRoleWithWebIdentity`.
Same standing-credential class [[H29]] killed in CI and [[M71]] targets on the
mini — extended **into the cluster**.

## What it creates

- **Public OIDC discovery bucket** `wind-cluster-oidc-830881980142` — holds the
  only two public-read objects in the account: `/.well-known/openid-configuration`
  and `/keys.json` (the cluster's public SA signing keys, copied from
  `kubectl get --raw /openid/v1/jwks`). Issuer URL =
  `https://wind-cluster-oidc-830881980142.s3.us-west-2.amazonaws.com` (dotless
  bucket → single-label host → valid under the `*.s3.us-west-2.amazonaws.com` cert).
- **IAM OIDC provider** for that issuer URL (thumbprint computed live from the S3
  endpoint cert chain).
- **Per-workload roles** (inline least-priv policies), trust locked to the exact
  namespace/ServiceAccount:
  | Role | Trusted SA(s) | Scope |
  |---|---|---|
  | `wind-irsa-velero` | `velero:velero-server` | velero bucket RW |
  | `wind-irsa-s3-sync` | `backups:s3-sync-*`, `backups:unifi-backup`, `backups:daily-report` | archive / logs.archive / archive-test / infra (== `s3-backup-kubernetes-policy.json`) |
  | `wind-irsa-barman` | `postgres:postgres-cluster`, `cue:cue-db` | postgres-barman bucket RW |
  | `wind-irsa-cloudwatch-read` | `auto-remediation:remediation-controller`, `cloudwatch-to-loki:default` | CloudWatch Logs read |

## Apply (CI-only, M82)

Via the `Cluster IRSA Terraform` workflow (`.github/workflows/terraform-cluster-irsa.yml`)
— `workflow_dispatch` → `plan` / `apply`. CI assumes `gh-actions-terraform` (OIDC),
whose scoped IAM policy already permits OIDC-provider + role + policy creation, so
**no admin bootstrap is needed**. PRs auto-plan; pushes to `main` plan; apply is manual.

This stack is **safe to apply ahead of the disruptive cutover** — the provider,
bucket, and roles do nothing until (Phase 3) the apiserver issuer is flipped to the
issuer URL AND (Phase 4) a ServiceAccount is annotated with a role ARN.

## Rollout phases (see `docs/runbooks/irsa-workload-identity.md`)

1. **Phase 1–2 (this stack):** publish discovery/JWKS + create provider + roles.
2. **Phase 3 (disruptive):** set kube-apiserver `--service-account-issuer` to
   `issuer_url` (keep `https://kubernetes.default.svc.cluster.local` as a secondary
   accepted issuer so existing tokens keep validating). Rolling restart cp2/cp3,
   cp1 LAST (no HA API VIP).
3. **Phase 4:** deploy the pod-identity webhook, annotate each SA with its
   `role_arns` output, drop the static-key secret refs, verify per-workload, delete
   the static-key secrets, then **rotate** (not delete — [[H29]]) the shared key.

## Maintenance

- **Re-sync `keys.json` ONLY if the SA signing key (`sa.key`) is rotated** — then
  copy `kubectl get --raw /openid/v1/jwks` over `keys.json` and re-apply.
- Adding a workload: add an entry to `local.roles` in `main.tf` (SA subject + inline
  policy), apply, annotate the SA.
