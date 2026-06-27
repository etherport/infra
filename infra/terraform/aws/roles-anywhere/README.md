# roles-anywhere (M71)

IAM Roles Anywhere foundation so the **headless mini** mints short-lived AWS creds from a
step-ca X.509 client cert instead of the standing static `~/.aws/credentials [homelab]` key.

**Design + the full rationale:** [`docs/planning/m71-roles-anywhere-plan.md`](../../../../docs/planning/m71-roles-anywhere-plan.md).
**Mini-side setup:** [`docs/runbooks/aws-roles-anywhere-mini.md`](../../../../docs/runbooks/aws-roles-anywhere-mini.md).

## What this creates

- `aws_rolesanywhere_trust_anchor.wind` — trusts certs chaining to the step-ca root
  (`step-ca-root.pem`, the public CA cert).
- `aws_iam_role.mini_ra` (`wind-mini-roles-anywhere`) — trust policy scoped to (a) this trust
  anchor and (b) Subject CN `mini.wind.etherport.net`; permissions = the `terraform-*` policies.
- `aws_rolesanywhere_profile.mini` (`wind-mini`) — 1h sessions.

## ⚠️ NOT YET APPLIED — three owner-gated prerequisites

This stack is **authored, not applied**. Before `apply`:

1. **CI rolesanywhere perms** — apply `../iam-policies/terraform-roles-anywhere.json` to the
   `gh-actions-terraform` CI user (console; IAM is console-managed here). Without it the apply
   fails (`gh-actions-terraform` has no `rolesanywhere:*`).
2. **Policy-scope decision + quota** — `var.attached_policy_names` defaults to full
   `terraform-homelab` parity (~20 policies). AWS caps managed policies per role at 10 (default;
   max 20, raise via Service Quotas `L-0DA4ABF3`). Either raise the quota to ≥20, or trim the
   list to ≤10 (TF is CI-only since M82, so a curated debug subset is defensible). **Confirm the
   real policy names** against the account first (`aws iam list-attached-user-policies
   --user-name terraform-homelab` + the groups, from `claude-admin`).
3. **Mini-side** — `docs/runbooks/aws-roles-anywhere-mini.md` (step-ca leaf cert + signing helper).

## Apply (after the prerequisites)

```bash
# via CI (preferred — OIDC, no local creds):
#   GH Actions → "Roles Anywhere Terraform" → Run workflow → plan, review (clean create), → apply
# or locally for debug (needs the homelab profile rendered):
terraform init && terraform plan && terraform apply
```

Outputs `trust_anchor_arn` / `profile_arn` / `role_arn` feed the mini's `credential_process`.

## Files

| File | Purpose |
|------|---------|
| `main.tf` | trust anchor + role (+ trust policy) + policy attachments + profile |
| `variables.tf` | region/account, `mini_cert_cn`, `attached_policy_names` (the decision) |
| `outputs.tf` | the 3 ARNs the mini needs |
| `step-ca-root.pem` | step-ca root CA (public) — the trust-anchor source |
| `backend.tf` / `providers.tf` | S3 state (`aws/roles-anywhere/…`) + aws ~> 6.0 |
