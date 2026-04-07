# Public Web Infrastructure Reference

**Purpose:** Documentation of AWS resources for the stopthecastle.com and smithforsb.com campaign sites. These resources are **out of scope** for the homelab infrastructure and should be migrated to a separate repository.

**Created:** 2026-04-06

---

## Overview

This infrastructure hosts public-facing campaign websites, completely separate from homelab infrastructure. It includes:

- WordPress site on EC2
- Static assets via S3 + CloudFront
- DNS via Route53
- SSL certificates via ACM

---

## AWS Resources

### VPC & Networking

| Resource | Name/ID | CIDR/Details |
|----------|---------|--------------|
| VPC | `public-web-vpc` | 10.11.0.0/20 |
| Subnets | `public-web-subnet-*` | 4 subnets across AZs |
| Internet Gateway | `public-web-igw` | Attached to VPC |
| Route Tables | `public-web-rtb-*` | 4 route tables |

### EC2 Instances

| Instance | Type | IP | Purpose |
|----------|------|-----|---------|
| `public-web_wordpress_stopthecastle` | t3.micro | 54.149.26.169 | WordPress site |

### Elastic IPs

| IP | Name | Association |
|----|------|-------------|
| 54.149.26.169 | `public-web_wordpresss_castle_ip` | WordPress instance |

### Security Groups

| Name | Purpose |
|------|---------|
| `public-web_cloudfront_sg` | Allow CloudFront IPs |
| `public-web_allow-ssh_sg` | SSH access |

### S3 Buckets

| Bucket | Purpose |
|--------|---------|
| `smithforsb.com` | Static website hosting |
| `static.stopthecastle.com` | WordPress static assets |
| `cflogs.grahamsmith.net` | CloudFront access logs |

### CloudFront Distributions

| ID | Domain | Origin |
|----|--------|--------|
| `E1877NKA6OHGR2` | smithforsb.com | S3: smithforsb.com |
| `EGLD2S71PI0A` | static.stopthecastle.com | S3: static.stopthecastle.com |

### Route53 Hosted Zones

| Zone | Purpose |
|------|---------|
| `stopthecastle.com` | Primary campaign domain |
| `smithforsb.com` | Alternate campaign domain |

### ACM Certificates (us-east-1 for CloudFront)

| Domain | Purpose |
|--------|---------|
| `smithforsb.com` | CloudFront SSL |
| `stopthecastle.com` | CloudFront SSL |
| `smith4sb.com` | Alternate domain SSL |

### SES Identities

| Identity | Type |
|----------|------|
| `stopthecastle.com` | Domain |
| `smithforsb.com` | Domain |
| `mgoodwin.us@gmail.com` | Email (campaign contact) |

---

## Architecture

```
                    ┌─────────────────┐
                    │   CloudFront    │
                    │  (CDN + SSL)    │
                    └────────┬────────┘
                             │
              ┌──────────────┴──────────────┐
              │                             │
              ▼                             ▼
    ┌─────────────────┐           ┌─────────────────┐
    │  S3 Bucket      │           │  EC2 WordPress  │
    │ (static assets) │           │  (dynamic site) │
    └─────────────────┘           └─────────────────┘
                                          │
                                          ▼
                                  ┌─────────────────┐
                                  │  public-web VPC │
                                  │  10.11.0.0/20   │
                                  └─────────────────┘
```

---

## Migration Notes

When creating a separate repository for this infrastructure:

1. **Terraform State:** Use a separate state file/bucket from homelab
2. **IAM:** May need dedicated IAM user or use existing `terraform-homelab` user
3. **Shared Resources:**
   - `cflogs.grahamsmith.net` S3 bucket could stay in homelab if used for other purposes
   - SES identities may have cross-dependencies (review before migrating)

---

## Terraform Import Commands

```bash
# VPC
terraform import aws_vpc.public_web vpc-XXXXXXXXX

# EC2
terraform import aws_instance.wordpress i-XXXXXXXXX
terraform import aws_eip.wordpress eipalloc-XXXXXXXXX

# Security Groups
terraform import aws_security_group.cloudfront sg-XXXXXXXXX
terraform import aws_security_group.ssh sg-XXXXXXXXX

# S3
terraform import aws_s3_bucket.smithforsb smithforsb.com
terraform import aws_s3_bucket.static_stopthecastle static.stopthecastle.com

# CloudFront
terraform import aws_cloudfront_distribution.smithforsb E1877NKA6OHGR2
terraform import aws_cloudfront_distribution.static_stopthecastle EGLD2S71PI0A

# Route53
terraform import aws_route53_zone.stopthecastle ZXXXXXXXXX
terraform import aws_route53_zone.smithforsb ZXXXXXXXXX

# ACM (us-east-1)
terraform import aws_acm_certificate.smithforsb arn:aws:acm:us-east-1:ACCOUNT:certificate/XXXXX
terraform import aws_acm_certificate.stopthecastle arn:aws:acm:us-east-1:ACCOUNT:certificate/XXXXX
```

---

## Related Documentation

- [AWS Migration Plan](../../infra/terraform/aws/MIGRATION_PLAN.md) - Homelab migration (excludes these resources)
