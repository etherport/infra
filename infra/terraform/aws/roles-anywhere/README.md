# roles-anywhere (M71)

IAM Roles Anywhere foundation so the **headless mini** mints short-lived AWS creds from a
step-ca X.509 client cert instead of the standing static `~/.aws/credentials [homelab]` key.

**Design + the full rationale:** [`docs/planning/archive/m71-roles-anywhere-plan.md`](../../../../docs/planning/archive/m71-roles-anywhere-plan.md).
**Mini-side setup:** [`docs/runbooks/aws-roles-anywhere-mini.md`](../../../../docs/runbooks/aws-roles-anywhere-mini.md).

## What this creates

- `aws_rolesanywhere_trust_anchor.wind` — trusts certs chaining to the step-ca root
  (`step-ca-root.pem`, the public CA cert).
- `aws_iam_role.mini_ra` (`wind-mini-roles-anywhere`) — trust policy scoped to (a) this trust
  anchor, (b) Subject CN `mini.wind.etherport.net`, (c) issuer CN `wind Homelab CA Intermediate CA`;
  permissions = **plan/debug scope** (see below).
- `aws_iam_role_policy_attachment.readonly` + `aws_iam_role_policy.tfstate` — `ReadOnlyAccess` plus
  an inline policy that allows S3 state read/write + lock on `terraform.wind.etherport.net` only and
  **Denies** object-data reads (`s3:GetObject`+`GetObjectVersion`) on every *other* bucket +
  `secretsmanager:GetSecretValue`/`BatchGetSecretValue` + `ssm:GetParameter*` + `kms:Decrypt`
  (hardened 2026-06-28). ⚠️ **Residual:** the role can still read the *whole* tfstate bucket, and TF
  state holds plaintext secrets — so it is NOT a full secret-exfil block, just the dedicated
  backup/secret stores. `DeleteObject` is scoped to `*.tflock` (lock release only).
- `aws_rolesanywhere_profile.mini` (`wind-mini`) — 1h sessions.

## ✅ APPLIED 2026-06-28 (AWS-side)

Applied via CI (run `28330240921`, `4 added, 0 changed`). The 3 ARNs are baked into the mini runbook.
The three original prerequisites resolved as:

1. **CI rolesanywhere perms — already present.** `gh-actions-terraform` has **PowerUserAccess**, which
   covers `rolesanywhere:*` (PowerUser = all services except iam/org/account). No extra grant; the
   redundant `iam-policies/terraform-roles-anywhere.json` was deleted.
2. **Scope = plan/debug-only** (not full `terraform-*` parity). TF is CI-only (M82), so the mini only
   does rare local `plan`/inspect → `ReadOnlyAccess` + the inline tfstate-RW/deny-data-reads policy.
   Sidesteps the 10-managed-policy-per-role quota entirely; least-privilege.
3. **Mini-side** — the only remaining work: `docs/runbooks/aws-roles-anywhere-mini.md` (step-ca leaf
   cert + signing helper). Owner-only (the agent can't reach the mini).

## Re-apply / change

```bash
# via CI (the only path — OIDC, no local creds):
#   GH Actions → "Roles Anywhere Terraform" → Run workflow → plan, review, → apply
#   (or dispatch via the M92 PAT). NB a push-triggered plan run contends the S3 lockfile
#   with a concurrent dispatched apply — let the plan run finish, then dispatch apply.
```

Outputs `trust_anchor_arn` / `profile_arn` / `role_arn` feed the mini's `credential_process`.

## Files

| File | Purpose |
|------|---------|
| `main.tf` | trust anchor + role (+ trust policy) + ReadOnlyAccess attach + inline tfstate policy + profile |
| `variables.tf` | region, `mini_cert_cn`, `mini_cert_issuer_cn`, `tfstate_bucket`, session TTL |
| `outputs.tf` | the 3 ARNs the mini needs |
| `step-ca-root.pem` | step-ca root CA (public) — the trust-anchor source (committed via a `.gitignore` negation) |
| `backend.tf` / `providers.tf` | S3 state (`aws/roles-anywhere/…`) + aws ~> 6.0 |
