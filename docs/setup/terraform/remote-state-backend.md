# Terraform Remote State (S3 backend)

**Status**: ✅ Implemented (2025-12-31) · S3-native locking since 2026-04.

Terraform state lives in the **S3 bucket `terraform.wind.etherport.net`**
(us-west-2). Locking is **S3-native** (`use_lockfile = true`) — there is **no
DynamoDB lock table** (deleted 2026-04; AWS provider >= 5.x does in-S3 locking).

## Backend block

Every TF module carries its own `backend.tf` with a per-module `key`:

```hcl
terraform {
  backend "s3" {
    bucket       = "terraform.wind.etherport.net"
    key          = "proxmox/k8s-vms/terraform.tfstate"   # per-module path
    region       = "us-west-2"
    use_lockfile = true                                   # S3-native lock (no DynamoDB)
    encrypt      = true
    profile      = "homelab"                              # CI overrides → empty (OIDC)
  }
}
```

Bucket properties: versioning enabled, AES-256 SSE, noncurrent versions expire
after 30 days, public access blocked.

## State paths (one key per module)

| Module | State key |
|--------|-----------|
| Proxmox VMs | `proxmox/k8s-vms/terraform.tfstate` |
| AWS Networking | `aws/networking/terraform.tfstate` |
| AWS Compute | `aws/compute/terraform.tfstate` |
| AWS ACM | `aws/acm/terraform.tfstate` |
| AWS S3 | `aws/s3/terraform.tfstate` |
| AWS SES | `aws/ses/terraform.tfstate` |
| Lambda modules | `aws/<module>/terraform.tfstate` |
| Cloudflare (etherport.net) | `cloudflare/terraform.tfstate` |

(`ls infra/terraform/*/backend.tf` and grep `key =` for the authoritative set.)

> **Removed paths** (state objects still in S3 for audit; modules deleted):
> `aws/load-balancing/` (ALB decom 2026-05-27), `aws/route53/` (Route53 → CF
> migration 2026-05-25), `cloudflare-personal/` (split to the personal-web repo
> 2026-05-27).

## Auth

- **CI (canonical):** AWS via GitHub→AWS **OIDC** (no static keys); `profile`
  overridden to empty (`-backend-config="profile="`).
- **Local debug (rare):** `profile = "homelab"`, rendered from SOPS on demand
  with `scripts/render-aws-credentials.sh`. IAM user `terraform-homelab`,
  module-scoped policies in `infra/terraform/aws/iam-policies/`. **Never delete
  that access key — rotate-only** (shared with the local homelab profile).

## Day-to-day

`terraform plan` / `apply` need no extra flags — the backend reads/writes S3 and
takes the S3 lock automatically. State history: `aws s3api list-object-versions
--bucket terraform.wind.etherport.net --prefix <module>/terraform.tfstate`.

## Stuck lock

A killed run can leave the `.tflock` object behind. Clear it with:

```bash
terraform force-unlock <LOCK_ID>     # ID is printed in the lock error
```

(or delete the `<key>.tflock` object in S3 directly).

## References

- [Terraform S3 Backend](https://developer.hashicorp.com/terraform/language/settings/backends/s3)
- IAM policies: `infra/terraform/aws/iam-policies/README.md`
