# github-oidc (H29)

Retires the 22 CI workflows' long-lived static AWS keys in favour of GitHub-OIDC
short-lived per-run credentials (`AssumeRoleWithWebIdentity`).

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

## Bootstrap (one-time, needs ADMIN — claude-admin cannot do this)
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

## Cutover (after bootstrap — keys + role coexist; migrate, verify, then delete keys)
Per workflow, 3 edits: add `permissions: id-token: write`, swap
`configure-aws-credentials` to `role-to-assume: <role_arn>`, drop the
`aws-access-key-id`/`aws-secret-access-key` inputs. Keep `AWS_PROFILE=""` /
`-backend-config="profile="`.

1. Migrate **one GitHub-hosted** workflow first (`terraform-s3.yml`) → verify PR plan + dispatch apply (CloudTrail shows `AssumeRoleWithWebIdentity`).
2. Migrate **one self-hosted** workflow (`terraform-unifi.yml`) → the runner-OIDC gate (confirm no ambient `~/.aws/credentials` on the gh-runner VM masks the role).
3. Roll the remaining ~20 in batches.
4. When `grep -rl AWS_ACCESS_KEY_ID .github/workflows` is empty: deactivate the `terraform-homelab` access key, soak one cycle, then delete the key + the `AWS_ACCESS_KEY_ID`/`_SECRET` GH secrets.

Every step before key deletion is a single-file `git revert`.
