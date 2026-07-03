# github-oidc (H29)

GitHub-OIDC short-lived per-run AWS credentials (`AssumeRoleWithWebIdentity`) for
CI. **Cutover complete** — every AWS-touching workflow assumes the
`gh-actions-terraform` role; the old long-lived static CI keys are gone.

## What it creates
- An IAM **OIDC provider** for `token.actions.githubusercontent.com`.
- Role **`gh-actions-terraform`** trusted ONLY by `repo:sparked-diamond/infra` on
  `main` + `pull_request`.
- Permissions = AWS-managed **`PowerUserAccess`** (all non-IAM services CI's
  terraform touches) **+** `gh-actions-terraform-iam` (scoped IAM/OIDC writes, with
  a Deny on attaching `AdministratorAccess`/`IAMFullAccess` → no escalation).

> **Scope note:** this is broader than the 20 resource-prefixed `terraform-*`
> policies the static CI user carries (PowerUser is service-wide), but it's bounded
> by OIDC trust + the anti-escalation Deny, and it's a net security win (short-lived
> vs long-lived keys). Tightening to per-stack roles / the exact scoped set is a
> follow-up (would need the IAM policies-per-role quota raised past 10).

## Bootstrap (one-time, DONE — kept for a from-scratch rebuild; needs ADMIN)
claude-admin is PowerUser (no `iam:*`); this stack creates IAM objects, so the
first apply needs admin. `gs_admin` has AdministratorAccess but is console-only —
so create a temporary key for it, apply, then delete the key:

```bash
# 1. (console, as gs_admin) IAM → Users → gs_admin → Create access key (CLI).
#    Configure it locally: aws configure --profile gs-admin-temp
cd infra/terraform/aws/github-oidc
AWS_PROFILE=gs-admin-temp terraform init
AWS_PROFILE=gs-admin-temp terraform apply          # creates provider + role + policy
terraform output role_arn                          # note the ARN

# If the OIDC provider already exists in the account:
#   AWS_PROFILE=gs-admin-temp terraform import aws_iam_openid_connect_provider.github \
#     arn:aws:iam::830881980142:oidc-provider/token.actions.githubusercontent.com
#   then re-run apply.

# 2. DELETE the temp key (console or CLI) once apply succeeds. Bootstrap is done;
#    nothing else ever needs admin — CI assumes the role from here.
```

## Cutover (DONE — recipe kept for adding a NEW AWS-touching workflow)
Per workflow, 3 edits: add `permissions: id-token: write`, use
`configure-aws-credentials` with `role-to-assume: <role_arn>`, and no
`aws-access-key-id`/`aws-secret-access-key` inputs. Keep `AWS_PROFILE=""` /
`-backend-config="profile="`.

History: the migration ran GitHub-hosted-first (`terraform-s3.yml`), then a
self-hosted workflow (checking no ambient `~/.aws/credentials` on the gh-runner
VM masked the role), then the rest in batches; the static `terraform-homelab`
CI key + `AWS_ACCESS_KEY_ID`/`_SECRET` GH secrets were then deactivated/removed.
(The `terraform-homelab` IAM access key itself is retained for the local
`[homelab]` profile render — rotate-only, never delete; see CLAUDE.md §4.)
