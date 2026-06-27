# Terraform AWS Security Best Practices

> **⚠️ Current state (2026-06-26):** This homelab has moved well past the "Level 1
> long-lived keys" framing below — it now runs **Level 4 (CI/CD + OIDC)** for Terraform
> *plus* **IRSA** for in-cluster workloads:
> - **CI Terraform → GitHub→AWS OIDC** (H29): no static AWS keys in CI; the OIDC provider +
>   deployer role live in [`infra/terraform/aws/github-oidc/`](../../../infra/terraform/aws/github-oidc/).
> - **In-cluster workloads → IRSA** (M75): velero, the s3-sync family, CNPG barman, and
>   cloudwatch-read get short-lived creds via `AssumeRoleWithWebIdentity` (projected SA token,
>   aud `sts.amazonaws.com`) — **no static AWS keys in etcd**. See
>   [`docs/runbooks/irsa-workload-identity.md`](../../runbooks/irsa-workload-identity.md).
> - **Devbox holds NO standing AWS creds** (M82) — TF is CI-only; rare local debug re-renders a
>   throwaway profile from SOPS on demand.
> - The `terraform-homelab` access key still exists but is **rare-local-debug only** (rotate, never delete).
>
> The "Level 1 (Current Setup)" and "I recommend Level 2" sections below are kept for their
> educational value, but no longer describe reality.

How to securely manage AWS infrastructure with Terraform, from homelab to production.

## The Security Challenge

Terraform needs broad permissions to create, modify, and delete infrastructure. This creates a security surface:

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Security Concern: Terraform Credentials                               │
│                                                                         │
│  If compromised, an attacker could:                                     │
│  - Delete all infrastructure                                            │
│  - Exfiltrate data from S3/databases                                    │
│  - Create backdoors (new IAM users, Lambda functions)                   │
│  - Rack up massive AWS bills (crypto mining)                            │
│  - Access secrets in Secrets Manager                                    │
└─────────────────────────────────────────────────────────────────────────┘
```

## Security Strategies (Ordered by Complexity)

### Level 1: Scoped Long-Lived Credentials (Current Setup)

**What we have now:**
- IAM user `terraform-homelab` with access keys
- Keys stored in `~/.aws/credentials` and 1Password
- Permissions scoped to specific resources where possible

**Mitigations:**
```
┌─────────────────────────────────────────────────────────────────────────┐
│  1. Resource-scoped policies (not "*")                                  │
│     ✓ "Resource": "arn:aws:lambda:*:*:function:ddns-*"                  │
│     ✗ "Resource": "*"                                                   │
│                                                                         │
│  2. Naming conventions enable scoping                                   │
│     - All DDNS resources prefixed with "ddns-"                          │
│     - IAM policies scoped to that prefix                                │
│                                                                         │
│  3. Credentials in 1Password (not plaintext files)                      │
│     - Encrypted at rest                                                 │
│     - Audit log of access                                               │
│     - Can be rotated easily                                             │
└─────────────────────────────────────────────────────────────────────────┘
```

**Risks:**
- Long-lived credentials can be stolen from disk
- No MFA requirement for API calls
- No expiration on access keys

**Best for:** Homelabs, small teams, getting started

---

### Level 2: Assumed Roles with MFA (Recommended for Homelab)

Instead of long-lived credentials, use temporary credentials via role assumption:

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Flow: MFA-Protected Role Assumption                                    │
│                                                                         │
│  1. IAM User (minimal permissions)                                      │
│     └── Only permission: sts:AssumeRole (with MFA required)             │
│                                                                         │
│  2. IAM Role (terraform-deployer)                                       │
│     └── Full Terraform permissions                                      │
│     └── Trust policy requires MFA                                       │
│                                                                         │
│  3. Workflow:                                                           │
│     $ aws sts assume-role --role-arn arn:aws:iam::xxx:role/terraform    │
│       --serial-number arn:aws:iam::xxx:mfa/mydevice                     │
│       --token-code 123456                                               │
│     $ export AWS_ACCESS_KEY_ID=... (temporary, expires in 1 hour)       │
│     $ terraform apply                                                   │
└─────────────────────────────────────────────────────────────────────────┘
```

**Setup:**

1. Create the Terraform role:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::830881980142:user/terraform-homelab"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "Bool": {
          "aws:MultiFactorAuthPresent": "true"
        }
      }
    }
  ]
}
```

2. Attach Terraform permissions to the role (not the user)

3. Give the user only AssumeRole permission:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "arn:aws:iam::830881980142:role/terraform-deployer"
    }
  ]
}
```

4. Use a wrapper script:
```bash
#!/bin/bash
# terraform-with-mfa.sh
MFA_SERIAL="arn:aws:iam::830881980142:mfa/graham"
ROLE_ARN="arn:aws:iam::830881980142:role/terraform-deployer"

read -p "MFA Code: " MFA_CODE

CREDS=$(aws sts assume-role \
  --role-arn "$ROLE_ARN" \
  --role-session-name "terraform-$(date +%s)" \
  --serial-number "$MFA_SERIAL" \
  --token-code "$MFA_CODE" \
  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
  --output text)

export AWS_ACCESS_KEY_ID=$(echo $CREDS | cut -d' ' -f1)
export AWS_SECRET_ACCESS_KEY=$(echo $CREDS | cut -d' ' -f2)
export AWS_SESSION_TOKEN=$(echo $CREDS | cut -d' ' -f3)

terraform "$@"
```

**Benefits:**
- Credentials expire after 1 hour (configurable)
- MFA required for every session
- Stolen long-lived credentials are useless without MFA device

---

### Level 3: AWS SSO / Identity Center (Production Standard)

For teams and production, use AWS SSO (now called IAM Identity Center):

```
┌─────────────────────────────────────────────────────────────────────────┐
│  AWS SSO Flow                                                           │
│                                                                         │
│  1. $ aws sso login --profile terraform-prod                            │
│     → Opens browser for authentication                                  │
│     → Supports SAML (Okta, Azure AD, etc.)                              │
│     → MFA enforced by IdP                                               │
│                                                                         │
│  2. Credentials cached temporarily (~/.aws/sso/cache/)                  │
│     → Expire after 8-12 hours                                           │
│     → Auto-refresh on next command                                      │
│                                                                         │
│  3. $ terraform apply                                                   │
│     → Uses temporary credentials                                        │
│     → No long-lived keys anywhere                                       │
└─────────────────────────────────────────────────────────────────────────┘
```

**AWS CLI config for SSO:**
```ini
# ~/.aws/config
[profile terraform-prod]
sso_start_url = https://mycompany.awsapps.com/start
sso_region = us-west-2
sso_account_id = 830881980142
sso_role_name = TerraformDeployer
region = us-west-2
```

---

### Level 4: CI/CD Pipeline with OIDC (Production Best Practice)

Remove human credentials entirely - only CI/CD can deploy:

```
┌─────────────────────────────────────────────────────────────────────────┐
│  GitHub Actions + AWS OIDC                                              │
│                                                                         │
│  1. GitHub Actions workflow triggered on PR merge                       │
│                                                                         │
│  2. GitHub signs a JWT token proving:                                   │
│     - Repository: sparked-diamond/infra                                 │
│     - Branch: main                                                      │
│     - Workflow: deploy.yml                                              │
│                                                                         │
│  3. AWS validates JWT via OIDC federation                               │
│     - No secrets stored in GitHub                                       │
│     - No long-lived credentials                                         │
│                                                                         │
│  4. AWS returns temporary credentials for terraform-deployer role       │
│                                                                         │
│  5. Terraform runs with temporary credentials                           │
└─────────────────────────────────────────────────────────────────────────┘
```

**Benefits:**
- Zero stored secrets
- Immutable audit trail (git history)
- PR review before infrastructure changes
- No local `terraform apply` (all changes via CI/CD)

---

## State File Security

Terraform state contains sensitive data (resource IDs, sometimes secrets):

```
┌─────────────────────────────────────────────────────────────────────────┐
│  State File Risks                                                       │
│                                                                         │
│  terraform.tfstate may contain:                                         │
│  - Database passwords                                                   │
│  - API keys                                                             │
│  - Private IPs                                                          │
│  - Resource ARNs (useful for attackers)                                 │
└─────────────────────────────────────────────────────────────────────────┘
```

**Mitigations (current setup):**

1. **S3 backend with encryption:**
   ```hcl
   backend "s3" {
     bucket  = "terraform.wind.etherport.net"
     encrypt = true  # SSE-S3 encryption at rest
   }
   ```

2. **S3 bucket policy restricts access:**
   - Only `terraform-homelab` user can read/write

3. **S3-native locking prevents corruption (use_lockfile=true, no DynamoDB):**
   - Concurrent applies are blocked

4. **Never commit state to git:**
   - `.gitignore` excludes `*.tfstate*`

**Additional hardening:**
```hcl
# Use KMS for state encryption (stronger than SSE-S3)
backend "s3" {
  bucket         = "terraform.wind.etherport.net"
  encrypt        = true
  kms_key_id     = "arn:aws:kms:us-west-2:830881980142:key/xxx"
}
```

---

## Audit Logging

All AWS API calls are logged by CloudTrail:

```bash
# View recent Terraform activity
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=Username,AttributeValue=terraform-homelab \
  --max-results 20 \
  --profile homelab
```

**What gets logged:**
- Who made the call (IAM user/role)
- What action (CreateFunction, DeleteSecurityGroup, etc.)
- When (timestamp)
- Source IP
- Success/failure

---

## Recommended Setup for This Homelab

> **Update:** The recommendation below (Level 2, MFA role assumption) was the original plan, but
> the homelab has since gone further — it now runs **Level 4 (CI/CD + OIDC)** for Terraform
> ([`infra/terraform/aws/github-oidc/`](../../../infra/terraform/aws/github-oidc/), H29) **plus
> IRSA** for in-cluster AWS workloads (M75, [`docs/runbooks/irsa-workload-identity.md`](../../runbooks/irsa-workload-identity.md)).
> Standing long-lived keys are no longer the deploy path; the Level 2 architecture below is
> retained for reference only.

Given single-user homelab context, the original plan was **Level 2** (MFA-protected role assumption):

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Recommended Architecture                                               │
│                                                                         │
│  IAM User: terraform-homelab                                            │
│  └── Only permission: sts:AssumeRole (to terraform-deployer)            │
│  └── MFA device configured                                              │
│                                                                         │
│  IAM Role: terraform-deployer                                           │
│  └── Trust policy: requires MFA                                         │
│  └── Attached policies:                                                 │
│      ├── TerraformDDNSLambda (for ddns-lambda project)                  │
│      ├── TerraformNetworking (when you migrate VPC)                     │
│      ├── TerraformCompute (when you migrate EC2)                        │
│      └── ... (add as you migrate resources)                             │
│                                                                         │
│  State: S3 (native locking, use_lockfile=true)                                      │
│  └── Encrypted at rest                                                  │
│  └── Versioning enabled (recover from bad applies)                      │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Permission Scoping Strategy

Instead of one giant policy, create modular policies per project:

| Policy Name | Scope | Used By |
|-------------|-------|---------|
| `TerraformState` | S3 bucket (S3-native lock) | All projects |
| `TerraformDDNSLambda` | Lambda, API GW, Secrets Mgr (ddns-*) | ddns-lambda |
| `TerraformNetworking` | VPC, subnets, route tables, NACLs | networking |
| `TerraformSecurityGroups` | EC2 security groups | security-groups |
| `TerraformCompute` | EC2 instances, AMIs, EBS | compute |
| `TerraformLoadBalancer` | ALB, target groups, WAF | load-balancer |
| `TerraformLambdaAll` | All Lambda functions | lambda |
| `TerraformDNS` | Route53 zones and records | dns |
| `TerraformIAM` | IAM roles (not users) | iam |

**Attach only what's needed** - if working on DDNS Lambda, only attach that policy.

---

## Quick Reference: Policy Files

```
infra/terraform/aws/iam-policies/
├── terraform-ddns-lambda.json      # DDNS Lambda project
├── terraform-state.json            # S3 backend (shared; S3-native lock)
├── terraform-networking.json       # VPC resources (future)
├── terraform-compute.json          # EC2 resources (future)
└── terraform-full.json             # Everything (use sparingly)
```

---

## Credential Rotation

Rotate access keys periodically:

```bash
# 1. Create new access key
aws iam create-access-key --user-name terraform-homelab

# 2. Update ~/.aws/credentials and 1Password

# 3. Test new key
aws sts get-caller-identity --profile homelab

# 4. Delete old key
aws iam delete-access-key --user-name terraform-homelab --access-key-id AKIA...OLD
```

**Recommendation:** Rotate every 90 days, or immediately if exposure suspected.

---

## Summary: Security Tradeoffs

| Approach | Security | Convenience | Complexity |
|----------|----------|-------------|------------|
| Long-lived keys (Level 1) | Low | High | Low |
| MFA role assumption (Level 2) | Medium | Medium | Medium |
| AWS SSO (Level 3) | High | Medium | Medium |
| CI/CD + OIDC (Level 4) | Highest | Lower | High |

Level 2 with good credential hygiene is a reasonable middle ground for a homelab, but this homelab
runs **Level 4 (CI/CD + OIDC)** for Terraform plus **IRSA** for in-cluster workloads (see the banner
at the top) — the highest tier, with zero standing long-lived keys in the deploy path.
