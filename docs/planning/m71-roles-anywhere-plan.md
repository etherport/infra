# M71 — mini → IAM Roles Anywhere (kill the standing static AWS keys)

> **Status: ✅ AWS-SIDE APPLIED 2026-06-28** (CI run `28330240921`, sha `fc32bf2`). The trust
> anchor + IAM role + RA profile are live; the 3 ARNs are in
> [`../runbooks/aws-roles-anywhere-mini.md`](../runbooks/aws-roles-anywhere-mini.md). Of the three
> owner-gated steps below, **#1 (CI perms) and #2 (scope) are resolved**; **only #3 — the mini-side
> cert + signing-helper — remains** (owner-only; the agent can't reach the mini). This doc is now the
> design record + the mini-side runway.

## Goal

Replace the mini's standing plaintext static key `~/.aws/credentials [homelab]`
(`terraform-homelab`, never rotated) with **short-lived session creds minted on demand from an
X.509 client cert** — zero standing key on disk. (`[claude-admin]` PowerUser is removed separately
as interim-win (a) — see `docs/runbooks/udm-manual-hardening-actions.md` §8.)

## Why Roles Anywhere (recap)

The mini is a persistent **headless** on-prem host → SSO (`aws sso login`) is a poor fit (needs
periodic interactive login → breaks cron). [IAM Roles Anywhere](https://docs.aws.amazon.com/rolesanywhere/latest/userguide/introduction.html)
is the blessed pattern: an X.509 **trust anchor** (a CA) + a per-host **client cert** +
`aws_signing_helper` as a `credential_process` → STS hands back short-lived creds. No standing key.

## Architecture (the synergy: reuse step-ca as the trust anchor)

We already run **step-ca** (M76, VM 1006 `https://10.10.201.46:8443`) as the homelab X.509+SSH CA.
Reuse it as the RA trust anchor instead of standing up AWS Private CA (~$400/mo) or a second PKI:

```
 step-ca root CA  ──(trust anchor: CERTIFICATE_BUNDLE = step-ca-root.pem)──▶  AWS RA Trust Anchor
        │                                                                          │
        │ issues a leaf X.509 client cert (CN=mini.wind.etherport.net)             │ validates chain
        ▼                                                                          ▼
   mini ~/.config/roles-anywhere/{cert.pem,key.pem}  ──aws_signing_helper──▶  RA Profile ─▶ IAM Role
        (renewed by a launchd timer, like the devbox SSH cert)                        (terraform-* perms)
        │                                                                          │
        └────────────── credential_process in ~/.aws/config ───────────────▶ short-lived STS creds
```

- **Trust anchor** = step-ca **root** cert (`step-ca-root.pem`, public, ECDSA P-256, valid→2036).
  The mini's leaf is signed by step-ca's intermediate; the mini presents leaf+intermediate, RA
  validates up to the root. Committed in the stack (it's a public CA cert, not a secret).
- **IAM role** `wind-mini-roles-anywhere` — trust policy allows `rolesanywhere.amazonaws.com` to
  assume it **only** when (a) `aws:SourceArn` == our trust anchor AND (b) the cert subject CN ==
  `mini.wind.etherport.net` (RA exposes cert attrs as `aws:PrincipalTag/x509Subject/CN`). So only a
  step-ca-issued cert with that exact CN can assume the role.
- **RA profile** `wind-mini` — links the role, `duration_seconds = 3600` (1h sessions).
- **Permissions = PLAN/DEBUG scope** (decision #2 below): `ReadOnlyAccess` (managed) for plan refresh
  + an inline `tfstate-rw-and-deny-data-reads` that allows S3 state RW on `terraform.wind.etherport.net`
  only and **Denies** all other `s3:GetObject` + `secretsmanager:GetSecretValue`/`kms:Decrypt`. Far
  less than the write-capable `[homelab]` key it replaces, and dodges the per-role managed-policy quota.

## Three owner-gated steps — resolution

1. **✅ CI `rolesanywhere:*` perms — already had them.** `gh-actions-terraform` carries
   **PowerUserAccess**, which covers `rolesanywhere:*` (PowerUser = all services *except* iam/org/account;
   the role's own IAM perms come from `gh-actions-terraform-iam.json`). No extra grant was needed — the
   redundant `iam-policies/terraform-roles-anywhere.json` was **deleted**.
2. **✅ Scope decided 2026-06-28 = plan/debug-only** (no quota bump). Real applies run via CI (M82), so
   the mini only does rare local `terraform plan`/inspect → `ReadOnlyAccess` + the inline tfstate-RW /
   deny-data-reads policy above. This sidesteps the 10-managed-policy-per-role quota entirely (no
   `terraform-*` policy attachments, no group-membership problem) and is least-privilege: a short-lived
   debug session can refresh/plan but cannot read backup objects or secret values.
3. **⏳ Mini-side setup — THE ONLY REMAINING WORK** (the agent can't reach the mini): issue the leaf
   cert from step-ca, install `aws_signing_helper`, wire `credential_process` (the 3 ARNs are already
   filled into the runbook), install the renewal timer — full runbook:
   `docs/runbooks/aws-roles-anywhere-mini.md`.

## Apply sequence

1. ✅ (interim) remove `[claude-admin]` from the mini (`§8` runbook) — biggest blast cut. *(owner)*
2. ✅ CI perms — PowerUser already covers `rolesanywhere:*` (no action).
3. ✅ Scope = plan/debug-only (ReadOnlyAccess + tfstate inline); no quota bump.
4. ✅ Dispatched `terraform-roles-anywhere` → `apply` (run `28330240921`, `4 added, 0 changed`).
5. ✅ Outputs captured (trust_anchor / profile / role ARNs) → baked into the mini runbook.
6. ⏳ **Mini-side:** follow `docs/runbooks/aws-roles-anywhere-mini.md` → verify
   `aws sts get-caller-identity --profile homelab-ra` returns the assumed-role ARN. *(owner)*
7. ⏳ Cut over: point the mini's TF usage at the `homelab-ra` profile; once verified, **rotate then
   remove** the standing `[homelab]` static key (don't delete the `terraform-homelab` IAM *user* —
   H29 shared key; here we're removing the mini's *standing key file*, replaced by RA sessions). *(owner)*

## Verification

- `aws sts get-caller-identity --profile homelab-ra` on the mini → `assumed-role/wind-mini-roles-anywhere/...`.
- `~/.aws/credentials` has **no** `[homelab]` static key after cutover (only the `credential_process`
  profile in `~/.aws/config`).
- A `terraform plan` on a stack the mini debugs succeeds via the RA profile.

## Notes / decisions

- **step-ca dependency:** the mini now depends on step-ca being reachable to renew its X.509 cert
  (like the devbox SSH cert). step-ca down > cert TTL → mini can't mint AWS creds. Mitigate with a
  generous cert TTL (e.g. 24h, renewed every 8h) + the break-glass `[claude-admin]` (pulled from
  SOPS/laptop) for emergencies. **Reachability:** the mini (VLAN-202/tailnet) must reach step-ca
  `10.10.201.46:8443` — the M77 standalone-vms firewall allows `:8443` from the Servers VLAN +
  tailnet; confirm the mini's path (tailnet `100.79.165.113`-style or a VLAN-202→201 allow) during
  mini-side setup.
- **SES SMTP / other static creds** are out of scope (protocol-bound, not IAM session creds).
- Human laptops → **IAM Identity Center (SSO)** remains the target for interactive use (separate,
  unchanged).
