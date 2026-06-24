# AWS IAM review + `claude-admin` redesign — 2026-06-11

> **Status: Archived 2026-06-24.** Work complete; kept as an ADR/historical record. Current state: `docs/planning/outstanding-work.md`.

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

## Chosen design (owner, 2026-06-11): PowerUser + scoped IAM role-creation

claude-admin gets: **`PowerUserAccess`** (broad ops) + **`claude-admin-oneoff-roles`**
(create/manage IAM roles under the `claude-*` prefix) + the scoped `claude-admin-policy`
(its terraform-* IAM duties + read). The role-creation grant is made safe by a
**permissions-boundary delegation**: `claude-admin-oneoff-roles` only allows
`CreateRole` when `iam:PermissionsBoundary == claude-oneoff-boundary`, forbids
stripping that boundary, and the boundary (`claude-oneoff-boundary.json`) caps any
`claude-*` role to all-services-EXCEPT-IAM/Org. Net: claude-admin can spin up one-off
roles for tasks, but no role it creates (even with AdministratorAccess attached) can
perform IAM writes → no escalation path. Policy files in `infra/terraform/aws/iam-policies/`:
`claude-oneoff-boundary.json`, `claude-admin-oneoff-roles.json`, `claude-admin-policy.json` (scoped).

## Apply bundle (run in the VNC terminal as `claude-admin`, while `temp` is still attached)

`claude-admin` writes IAM via the (still-attached) `temp` grant for steps 1–3, then
detaches `temp` last. (The mini's `claude-admin` shell is classifier-gated on IAM
writes, so run this in your interactive VNC terminal.)

```bash
export AWS_PROFILE=claude-admin; ACC=830881980142; cd ~/code/infra
# 0. snapshot (reversibility)
aws iam list-attached-user-policies --user-name claude-admin > ~/claude-admin.before.json

# 1. create the boundary + the scoped role-mgmt policy (uses temp's CreatePolicy on *)
aws iam create-policy --policy-name claude-oneoff-boundary \
  --policy-document file://infra/terraform/aws/iam-policies/claude-oneoff-boundary.json
aws iam create-policy --policy-name claude-admin-oneoff-roles \
  --policy-document file://infra/terraform/aws/iam-policies/claude-admin-oneoff-roles.json

# 2. attach PowerUserAccess + the scoped role-mgmt policy (uses temp's AttachUserPolicy)
aws iam attach-user-policy --user-name claude-admin --policy-arn arn:aws:iam::aws:policy/PowerUserAccess
aws iam attach-user-policy --user-name claude-admin --policy-arn arn:aws:iam::$ACC:policy/claude-admin-oneoff-roles

# 3. push the scoped claude-admin-policy (drops secrets-write, scopes orphan-cleanup) (uses temp's CreatePolicyVersion)
aws iam create-policy-version --policy-arn arn:aws:iam::$ACC:policy/claude-admin-policy \
  --policy-document file://infra/terraform/aws/iam-policies/claude-admin-policy.json --set-as-default
#    if at the 5-version limit: aws iam list-policy-versions … then delete-policy-version the oldest

# 4. de-escalate: detach the temp policy (do this LAST — steps 1–3 needed its perms)
aws iam detach-user-policy --user-name claude-admin --policy-arn arn:aws:iam::$ACC:policy/claude-admin-temp

# verify
aws iam list-attached-user-policies --user-name claude-admin --query 'AttachedPolicies[].PolicyName' --output text
```

After this, the **`claude-admin-temp` policy object is orphaned** (detached, grants
nothing). claude-admin can't delete it post-detach (its DeletePolicy is scoped to
`terraform-*`); delete the object via the **`gs_admin` console** (IAM → Policies →
claude-admin-temp → Delete) when convenient — it's harmless meanwhile.

**Verify:** attachments = `claude-admin-policy` + `PowerUserAccess` +
`claude-admin-oneoff-roles` (no `claude-admin-temp`); `aws ec2 describe-instances`
works (PowerUser); `aws iam create-role --role-name claude-test …` **fails without**
`--permissions-boundary …/claude-oneoff-boundary` and **succeeds with** it.
**Rollback:** re-attach temp (`aws iam attach-user-policy --user-name claude-admin
--policy-arn …:policy/claude-admin-temp`), detach PowerUserAccess + oneoff-roles, and
`set-default-policy-version` claude-admin-policy back to the prior version (`~/claude-admin.before.json` has the pre-state).

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
