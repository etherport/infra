# AWS IAM review + `claude-admin` redesign — 2026-06-11

Covers **H31** and the broader "scope all AWS users correctly" ask. The IaC half
(policy files) is done in this commit; the **apply + full audit are gated on
admin/`claude-admin` credentials** (the mini's `terraform-homelab` profile can
only `list-users` — it can't enumerate roles/policies or write IAM).

## The `claude-admin` philosophy (confirmed with the owner)

`claude-admin` **stays a deliberate break-glass / one-off user, outside Terraform** —
so ad-hoc tasks don't require manually attaching a new policy each time. The fix is
not to *shrink* it to nothing, but to make it **broad-but-not-escalation-capable**:
it can operate across services, but cannot grant itself (or anyone) admin.

**Target attachment set:**
1. **AWS-managed `PowerUserAccess`** — full access to all services **except IAM,
   Organizations, Account**. This is the "do one-off tasks without me attaching a
   policy" capability, safely (no `iam:*` write → no escalation).
2. **`claude-admin-policy`** (customer-managed, this repo) — the *scoped* IAM work
   claude-admin legitimately does: manage `terraform-*` policies/groups, read-only
   IAM discovery, resource discovery. **Redesigned in this commit** (see below).

**Why this is safe:** PowerUserAccess grants no `iam:Create*/Attach*/PassRole`, and
`claude-admin-policy`'s IAM writes are scoped to `terraform-*` objects only. So
claude-admin can't attach a policy to itself, mint an admin role, or pass a
privileged role — the account-takeover paths are closed, while broad operational
power remains. (Optional future hardening: a permissions boundary — not needed
given PowerUser already excludes IAM.)

## What changed in this commit (IaC)

- **Deleted `claude-admin-temp.json`** — the orphaned `Phase6Cleanup` policy granting
  `iam:CreateRole/AttachUserPolicy/AttachRolePolicy/CreatePolicyVersion/PassRole`,
  `iam:DeleteUser`, `s3:DeleteBucket` etc. **all on `Resource:*`** (the escalation
  primitive). It was still attached live (confirmed 2026-06-11).
- **`claude-admin-policy.json` scoped:**
  - `IAMOrphanCleanup` (`DeleteAccessKey/DetachUserPolicy/DeleteUser`) `Resource:*`
    → `arn:aws:iam::830881980142:user/terraform-*` (can't delete arbitrary users).
  - `ResourceDiscoveryReadOnly` — removed `secretsmanager:GetSecretValue/PutSecretValue/UpdateSecret`
    on `*` (read/overwrite every secret); kept `ListSecrets`/`DescribeSecret`.

## Apply bundle (run with the `homelab`/admin profile, NOT as `claude-admin`)

```bash
ACC=830881980142
# 0. snapshot current state (reversibility)
aws iam list-attached-user-policies --user-name claude-admin > /tmp/claude-admin.before.json
aws iam get-policy-version --policy-arn arn:aws:iam::$ACC:policy/claude-admin-policy \
  --version-id "$(aws iam get-policy --policy-arn arn:aws:iam::$ACC:policy/claude-admin-policy --query Policy.DefaultVersionId --output text)" \
  > /tmp/claude-admin-policy.before.json

# 1. detach + delete the temp escalation policy
aws iam detach-user-policy --user-name claude-admin --policy-arn arn:aws:iam::$ACC:policy/claude-admin-temp
aws iam delete-policy       --policy-arn arn:aws:iam::$ACC:policy/claude-admin-temp

# 2. push the scoped claude-admin-policy (this repo's JSON) as the new default version
aws iam create-policy-version --policy-arn arn:aws:iam::$ACC:policy/claude-admin-policy \
  --policy-document file://infra/terraform/aws/iam-policies/claude-admin-policy.json --set-as-default
#    prune old versions if at the 5-version limit:
#    aws iam list-policy-versions --policy-arn …/claude-admin-policy   # then delete-policy-version the oldest

# 3. attach PowerUserAccess for broad one-off ops (replaces the deleted temp's "breadth")
aws iam attach-user-policy --user-name claude-admin --policy-arn arn:aws:iam::aws:policy/PowerUserAccess
```

**Verify:** `aws iam list-attached-user-policies --user-name claude-admin` shows
`claude-admin-policy` + `PowerUserAccess` (no `claude-admin-temp`); a smoke test as
claude-admin can e.g. `aws ec2 describe-instances` (PowerUser) but **cannot**
`aws iam attach-user-policy …` (denied). **Rollback:** re-create temp from
`/tmp/claude-admin.before.json` + `set-default-policy-version` to the prior version.

## Full IAM audit — script (run with `claude-admin` creds; it has the read set)

`terraform-homelab` lacks `GetAccountAuthorizationDetails`; `claude-admin`'s
`IAMReadOnly` does not include it either, so enumerate per-resource:

```bash
export AWS_PROFILE=claude-admin
echo "== USERS =="; aws iam list-users --query 'Users[].UserName' --output text | tr '\t' '\n' | while read u; do
  echo "--- $u ---"
  aws iam list-attached-user-policies --user-name "$u" --query 'AttachedPolicies[].PolicyName' --output text
  aws iam list-access-keys --user-name "$u" --query 'AccessKeyMetadata[].[AccessKeyId,Status,CreateDate]' --output text
  for k in $(aws iam list-access-keys --user-name "$u" --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
    aws iam get-access-key-last-used --access-key-id "$k" --query 'AccessKeyLastUsed.LastUsedDate' --output text
  done
done
echo "== CUSTOMER-MANAGED POLICIES with Resource:* on write actions =="
aws iam list-policies --scope Local --query 'Policies[].[PolicyName,Arn,DefaultVersionId]' --output text | while read n arn ver; do
  doc=$(aws iam get-policy-version --policy-arn "$arn" --version-id "$ver" --query 'PolicyVersion.Document' --output json)
  echo "$doc" | python3 -c "import json,sys; d=json.load(sys.stdin);
import re
for s in (d['Statement'] if isinstance(d['Statement'],list) else [d['Statement']]):
  acts=s.get('Action',[]); acts=[acts] if isinstance(acts,str) else acts
  res=s.get('Resource','')
  star=(res=='*' or (isinstance(res,list) and '*' in res))
  writ=[a for a in acts if any(w in a.lower() for w in ('create','put','attach','delete','passrole','update','*'))]
  if star and writ: print('  ⚠ $n :', writ[:6])"
done
```

**What to flag:** any user with policies broader than its job; unused access keys
(rotate/remove — `LastUsedDate` stale); any *write* action on `Resource:*` outside a
deliberate break-glass policy; the hand-managed `terraform-*` groups vs the documented
intent; stale/`-temp`/`-test` policies. Cross-check against `iam-policies/README.md`.

## To unblock (recommended)

Add a **`claude-admin` AWS profile on the mini** (paste creds via VNC — consistent
with claude-admin being the persistent ops/break-glass user, and *after* this
redesign it's no longer escalation-capable). Then I can run the audit + apply the
bundle headless. Alternatively, run the bundle + audit script yourself and paste the
audit output back.
