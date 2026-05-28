# Public-web repo split — migration runbook

Per task #82, the 3 personal/campaign domains move out of this
homelab repo into a separate `public-web` repo. This doc plans the
move; the actual execution is a single PR (or sequence of PRs) when
ready.

## Why split

- `homelab` repo's purpose is operating the home cluster + adjacent
  AWS infra. The campaign sites + personal domains have a different
  failure-domain, different audience for changes, different on-call
  expectations.
- Keeps the homelab repo focused as it grows. The 3 personal domains
  cumulatively add ~200 lines of TF + several K8s configs + planning
  docs that aren't relevant to homelab ops.
- Cleaner secret scoping — public-web doesn't need 1Password access
  to UDM keys, Twilio creds, Proxmox auth, etc.

## Domain → repo mapping

| Domain | Repo after split | Why |
|---|---|---|
| `etherport.net` | **homelab** (stays) | Operational infra. Tunnels, Access apps, internal services, SIP trunk. |
| `grahamsmith.net` | **public-web** | Personal forwarding-only domain. Email forwards via SES; no other infra ties. |
| `smithforsb.com` | **public-web** | Campaign redirect to Instagram; no AWS infra remaining. |
| `stopthecastle.com` | **public-web** | Campaign WordPress on EC2 + CloudFront. Most of the public-web stack. |

## What moves

### Cloudflare-managed (moves wholesale)
- `infra/terraform/cloudflare-personal/` entire directory:
  - `providers.tf` (CF + AWS providers — homelab keeps its own copies in `cloudflare/`)
  - `variables.tf` (3 zone IDs)
  - `backend.tf` (S3 state — destination bucket TBD per "Backend" section below)
  - `grahamsmith.tf`, `smithforsb.tf`, `stopthecastle.tf` (zone records)
  - `dnssec.tf` (zone DNSSEC + registrar DS records)
  - `outputs.tf` (DNSSEC values + zone IDs)

### AWS-managed (selective move)
- SES domain identities for the 3 domains — `infra/terraform/aws/ses/main.tf`.
  These need careful split since `ses/main.tf` also manages
  `etherport.net` identity. Refactor: leave etherport.net identity in
  homelab, move the 3 personal ones to public-web/aws/ses.
- Email-forward Lambda — `infra/terraform/aws/email-forward/`.
  Currently handles forwarding for all 4 domains via one Lambda. Two
  options:
  (a) Keep the Lambda in homelab + a list of forward addresses crosses
      the repo boundary. Cheaper, but the homelab repo retains
      knowledge of public-web addresses.
  (b) Split into 2 Lambdas — homelab keeps the etherport.net one,
      public-web gets its own. Clean separation but duplicates the
      Lambda code + IAM scaffolding.
  **Recommend (a)** — the Lambda is small, the cross-repo coupling is
  just a list of `forward_to → recipient` entries, and SES inbound
  rules are simple resources.
- Public-web AWS stack (CloudFront, S3, ACM, public-web VPC, EC2
  WordPress, security groups). Currently mostly NOT in TF (per
  `docs/planning/public-web-infrastructure.md`). The smithforsb pieces
  were deleted today. Remaining stopthecastle pieces — `static.stopthecastle.com`
  CloudFront + S3 bucket + ACM cert + EC2 WordPress instance. Import
  to TF in the new public-web repo.
- The `cflogs.grahamsmith.net` S3 bucket — was for CloudFront logs.
  Only used by stopthecastle's CloudFront now (smithforsb's was
  deleted). Move to public-web.

### Stays in homelab
- `infra/terraform/cloudflare/` — etherport.net zone (operational).
- `infra/terraform/aws/email-forward/` — the Lambda itself (per
  recommendation (a) above). The recipient list inside the Lambda env
  is updated to include the public-web addresses as managed in
  public-web repo's outputs.
- All non-DNS homelab AWS: VPCs, compute, ALB (gone), security groups
  not tied to public-web, ACM (etherport-only) etc.
- All K8s, Proxmox, UDM, Ansible.

## Migration steps (high-level)

### 1. Bootstrap `public-web` repo

```bash
gh repo create sparked-diamond/public-web --private --confirm
cd ~/code
gh repo clone sparked-diamond/public-web
cd public-web
```

Top-level scaffolding mirrors homelab:
```
public-web/
  README.md
  .gitignore
  .sops.yaml                # same age recipient as homelab (single key pair)
  .github/
    workflows/
      terraform-cloudflare.yml
      terraform-aws-ses.yml
      terraform-aws-cloudfront.yml
      ...
  terraform/
    cloudflare/             # ex-cloudflare-personal/
    aws/
      ses-personal/
      cloudfront-stopthecastle/
      ...
  docs/
    runbooks/
      smithforsb-redirect.md  # CF Single Redirect setup (currently manual)
```

### 2. S3 state buckets

Either:
(a) Reuse `terraform.wind.etherport.net` with different key prefixes
    (`public-web/cloudflare/terraform.tfstate`). Simple; coupled to
    homelab AWS account.
(b) New S3 bucket in a separate AWS account for public-web. Properly
    isolated; bigger lift.

**Recommend (a)** — homelab AWS account stays the single AWS account
for everything; isolation via IAM policies attached to a separate
`terraform-public-web` user.

### 3. Migrate TF state — cloudflare-personal

The `terraform.wind.etherport.net/cloudflare-personal/terraform.tfstate`
file has all the resources we want to move. Process:

```bash
# In homelab repo, terraform-export the state
cd infra/terraform/cloudflare-personal
terraform state pull > /tmp/cloudflare-personal.tfstate

# Move/rename in the new repo
cd ~/code/public-web/terraform/cloudflare
# Reuse the same backend key OR copy with new key:
aws s3 cp s3://terraform.wind.etherport.net/cloudflare-personal/terraform.tfstate \
          s3://terraform.wind.etherport.net/public-web/cloudflare/terraform.tfstate

# Update backend.tf in public-web to point at the new key
terraform init -reconfigure
terraform plan  # should show ZERO changes if everything was clean
```

### 4. Migrate TF code

Copy files from homelab/cloudflare-personal/ → public-web/terraform/cloudflare/.
Adjust:
- Backend key in `backend.tf`
- Provider config (drop the homelab-cloudflare-tf-token reference,
  add public-web-specific CF token in 1P)
- Variable defaults if needed

### 5. SES + email-forward

This is the most coupled piece. Approach:

Option A (recommended) — Lambda stays in homelab:

- In public-web, declare just the SES domain identities + DKIM + MX
  records (in cloudflare/). No Lambda.
- The homelab email-forward Lambda continues to process inbound for
  all 4 domains. Recipient list stays in
  `infra/terraform/aws/email-forward/main.tf` (`fwd_graham.recipients`).
- Public-web's TF outputs the recipient list it owns (just the public
  addresses). Could publish it as a JSON artifact via a GH Release for
  the homelab side to consume — or just keep it in homelab as a list
  that's manually maintained (it changes rarely).
- The SES inbound RULESET stays in homelab (it's account-level).

Option B — separate Lambda per repo:

- Duplicate the Lambda code into public-web. Each Lambda has its own
  recipient list. SES inbound rules in each repo target their own
  Lambda.
- Cleaner isolation but doubles the Lambda + IAM cost.

### 6. Public-web AWS stack (stopthecastle)

These pieces are NOT in TF today. Import them when bootstrapping
public-web/terraform/aws/:
- CloudFront distribution `EGLD2S71PI0A`
- S3 bucket `static.stopthecastle.com`
- S3 bucket `cflogs.grahamsmith.net` (still serves stopthecastle's
  CloudFront)
- ACM cert(s) for stopthecastle.com (us-east-1)
- EC2 WordPress instance + EIP + SGs + VPC

See `docs/planning/public-web-infrastructure.md` for the inventory +
import commands.

### 7. smithforsb redirect

The Single Redirect rule is currently manual in the CF dashboard. Add
to public-web/terraform/cloudflare/ when the CF token has the
"Dynamic Redirect: Edit" scope (per the earlier 1P note).

### 8. Cleanup in homelab

After public-web is fully running:
- Delete `infra/terraform/cloudflare-personal/`
- Update `infra/terraform/aws/ses/main.tf` to drop the 3 personal
  domain identities (keep etherport.net)
- Update `infra/terraform/aws/email-forward/main.tf` `forward_to`
  list — keep only homelab-side forwards if Option B was chosen, or
  keep all forwards if Option A.
- Update README — drop the personal-domain rows from the DNS table.
- Archive `docs/planning/public-web-infrastructure.md` (its content
  now lives in public-web).

### 9. CI / secrets

In public-web GH repo, set secrets:
- `CLOUDFLARE_API_TOKEN` (new token, scoped to the 3 personal zones)
- `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` (new IAM user
  `terraform-public-web` with policies for SES on the 3 domains +
  CloudFront/S3/ACM on stopthecastle)
- `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_*_ZONE_ID` for each of the 3 zones

## Effort estimate

- New repo bootstrap + initial commits + CI setup: 2 hours
- TF state migration (`cloudflare-personal` only): 1 hour with a clean
  plan; longer if there's any drift
- SES + email-forward refactor: 2 hours
- Import stopthecastle AWS stack into TF: 4 hours (this is the bulk of
  the work)
- Cleanup in homelab + verification: 2 hours
- **Total: ~1.5 days**

## When to do this

- After cert-manager DNS-01 migration lands (today's other open item).
- When you have a clean ~1 day window.
- BEFORE the next domain change to any of the 3 personal zones — once
  the split is decided, doing TF changes against
  `cloudflare-personal/` is technical debt.
