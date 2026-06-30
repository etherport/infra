# config — AWS Config recorders + aggregator (cloud tag-drift detection)

Drift detector #4. Records every supported AWS resource (both regions) so we can find
resources **not** tagged `ManagedBy=terraform` — i.e. resources that exist in the account
but aren't managed by our Terraform (the gap `terraform plan` structurally can't see).
Chosen over the free Tagging-API approach for ~100% coverage + change history.

## What this creates
- **2 configuration recorders** (us-west-2 + us-east-1), `recording_frequency = DAILY`,
  `all_supported = true`. `include_global_resource_types` is **true in us-west-2 only**
  (IAM/CloudFront/etc. recorded once — both ends in BOTH regions would double-bill).
- **1 S3 delivery bucket** (`config.wind.etherport.net`) with the load-bearing
  `config.amazonaws.com` bucket policy, SSE-S3, public-access-block, and a 365-day
  lifecycle expiry (the only unbounded-growth cost vector).
- **1 hand-rolled IAM role** (`wind-config-recorder`) + the AWS-managed
  `service-role/AWS_ConfigRole` + a scoped S3-delivery inline policy. **Deliberately NOT
  a service-linked role** — the `config.amazonaws.com` SLR is account-global and likely
  already exists, which would `EntityAlreadyExists` on first apply.
- **1 account aggregator** (`wind-account-aggregator`) — makes both regions queryable
  from one place. The aggregator + advanced queries are **FREE**.

## Cost (~$2/mo)
$0.003 per config item; **DAILY** recording (not continuous); **NO conformance packs**,
**NO managed Config rules** (those bill per-evaluation). The tag-finding is a **free
advanced query** in `.github/workflows/cloud-tag-drift.yml`. The S3 lifecycle caps
storage. Don't add a `required-tags` managed rule "because it's the native way" — it
bills per-eval and breaks the budget.

## ⚠️ The immutable finding: Config SQL cannot express "missing a tag"
AWS Config advanced-query SQL supports only `= IN BETWEEN AND OR NOT` — **no `IS NULL`,
no `NOT EXISTS`, no subqueries**, and it explicitly **cannot unpack/negate the nested
`tags` array**. `WHERE NOT (tags.key='ManagedBy' AND tags.value='terraform')` does **not**
mean "lacks the tag" — over a multi-valued array it matches nearly every tagged resource.

**So tag-absence is filtered CLIENT-SIDE**: the workflow `SELECT`s every resource *with*
its tags (positive), paginates `--next-token` (100/page; `.Results` is an array of JSON
**strings**), then keeps rows whose tags array has no `{ManagedBy, terraform}`:
```
jq -s '[ .[] | select( ([ .tags[]? | select(.key=="ManagedBy" and .value=="terraform") ] | length) == 0 ) ]'
```

## IAM
`gh-actions-terraform` (PowerUserAccess + the scoped IAM-write policy) applies this with
**zero IAM-policy edits** — `config:*` + `s3:*` come from PowerUser; `iam:CreateRole/
AttachRolePolicy` (for the recorder role) come from the `ManageIAMRoles` Sid, and the
anti-escalation Deny only blocks attaching `AdministratorAccess`/`IAMFullAccess` (not
`AWS_ConfigRole`). The **query** workflow reuses the same role (`config:SelectAggregate
ResourceConfig` + `config:GetAggregate*` are in PowerUser) — no separate read-only role.

## First-apply caveats (un-testable from the devbox — no standing AWS creds)
1. **Singleton collision** — one recorder + one delivery channel per region. If one
   already exists, the apply `EntityAlreadyExists`. Before apply, the operator should run
   `aws configservice describe-configuration-recorders --region us-west-2` (and us-east-1);
   if present, `terraform import` it.
2. **DAILY + global IAM** — a flat-DAILY recorder that also records global IAM may 400 on
   a specific type. If it does, add a `recording_mode_override { recording_frequency =
   "CONTINUOUS", resource_types = [...] }` for just that type in `modules/config-recorder` —
   don't chase it blind; let the apply reveal it.
3. After enabling, confirm the resource/CI counts (`aws configservice
   get-discovered-resource-counts`) to sanity-check the ~$2/mo estimate.

## Apply
Via `.github/workflows/terraform-config.yml` (plan on push / `apply` on dispatch, OIDC).
Then the `cloud-tag-drift.yml` query becomes meaningful once a DAILY snapshot exists +
the 5 newly-`default_tags`-ed stacks (ddns-lambda, dns-restrict-ip, email-forward,
homeassistant-alexa, twilio-webhook) re-apply.
