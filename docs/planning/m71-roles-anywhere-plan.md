# M71 — mini → IAM Roles Anywhere (kill the standing static AWS keys)

> **Status: FOUNDATION AUTHORED 2026-06-27, NOT YET APPLIED.** The Terraform stack
> (`infra/terraform/aws/roles-anywhere/`) + CI workflow + mini runbook are written but
> **blocked on three owner-gated steps** (below). This doc is the design + the apply runway.
> The agent cannot apply it (no admin AWS; the CI terraform role lacks `rolesanywhere:*`) or
> reach the mini.

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
- **Permissions** = the `terraform-*` customer-managed policies (parity with `terraform-homelab`),
  attached to the role. **⚠️ DECISION + QUOTA — see below.**

## ⚠️ Three owner-gated steps (the stack can't apply until these are done)

1. **Grant CI the `rolesanywhere:*` perms.** The CI terraform OIDC role (`gh-actions-terraform`)
   already has `iam:CreateRole/CreatePolicy/PassRole/AttachRolePolicy` but **no `rolesanywhere:*`**.
   Apply the new policy doc `infra/terraform/aws/iam-policies/terraform-roles-anywhere.json` to the
   CI terraform user/group (console — IAM is console-managed here, per `iam-policies/README.md`).
   THEN CI can `terraform apply` this stack.
2. **Decide the role's permission scope + raise the quota if needed.** `terraform-homelab` carries
   ~20 `terraform-*` policies, kept under AWS's 10-policy-per-**user** limit via **IAM groups** —
   but **a ROLE can't join groups**, and the default quota is **10 managed policies per role** (hard
   max 20, raisable via Service Quotas `L-0DA4ABF3`). Options, operator's call (set
   `var.attached_policy_names`):
   - **(default) Full parity:** attach all ~20 `terraform-*` policies → **raise the per-role quota to
     ≥20 first**. Drop-in replacement for `[homelab]`.
   - **Narrow for debug:** since TF is **CI-only now (M82)**, the mini's local TF is rare debug —
     attach a ≤10 curated subset (e.g. state + the stacks you actually debug locally), full apply via
     CI. Least-privilege, no quota bump.
   - ⚠️ The exact policy **ARNs/names must be confirmed** against the account (the agent guessed them
     from the `iam-policies/terraform-*.json` filenames, which the README says match AWS names —
     verify with `aws iam list-attached-group-policies` / `list-attached-user-policies` for
     `terraform-homelab` from `claude-admin`).
3. **Mini-side setup** (the agent can't reach the mini): issue the leaf cert from step-ca, install
   `aws_signing_helper`, wire `credential_process`, install the renewal timer — full runbook:
   `docs/runbooks/aws-roles-anywhere-mini.md`.

## Apply sequence (owner)

1. (interim, do first) remove `[claude-admin]` from the mini (`§8` runbook) — biggest blast cut.
2. Apply `terraform-roles-anywhere.json` to the `gh-actions-terraform` CI user (console).
3. Confirm/populate `var.attached_policy_names` (decision #2); raise the per-role quota if full-parity.
4. Dispatch the `terraform-roles-anywhere` workflow → `plan`, review (must be a clean create), → `apply`.
5. Note the 3 outputs (trust_anchor_arn, profile_arn, role_arn).
6. Mini-side: follow `docs/runbooks/aws-roles-anywhere-mini.md` → verify
   `aws sts get-caller-identity --profile homelab-ra` returns the assumed-role ARN.
7. Cut over: point the mini's TF usage at the `homelab-ra` profile; once verified, **rotate then
   remove** the standing `[homelab]` static key (don't delete the `terraform-homelab` IAM *user* —
   H29 shared key; here we're removing the mini's *standing key file*, replaced by RA sessions).

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
  tailnet; confirm the mini's path (tailnet `100.74.216.102`-style or a VLAN-202→201 allow) during
  mini-side setup.
- **SES SMTP / other static creds** are out of scope (protocol-bound, not IAM session creds).
- Human laptops → **IAM Identity Center (SSO)** remains the target for interactive use (separate,
  unchanged).
