# AWS Infrastructure Terraform Migration Plan

## Overview

This document outlines the plan to migrate existing homelab AWS resources into Terraform management.

**Scope:** Homelab infrastructure only (`private-infra` VPC and related resources).

**Out of Scope:** Public web hosting infrastructure (`public-web` VPC, stopthecastle.com, smithforsb.com). These resources are documented separately in `docs/planning/public-web-infrastructure.md` for future migration to a dedicated repository.

## Current State

### Already in Terraform

| Module | Resources Managed |
|--------|-------------------|
| `ddns-lambda` | Lambda function, API Gateway, IAM role, CloudWatch logs, Secrets Manager |
| `dns-restrict-ip` | Lambda function, IAM role, CloudWatch logs, EventBridge rule |
| `email-forward` | Lambda function, IAM role, S3 bucket trigger, CloudWatch logs |
| `homeassistant-alexa` | Lambda function, IAM role, Secrets Manager |
| `snapshot-archive` | Lambda function, IAM role, CloudWatch logs, EventBridge rule, SES |
| `external-monitoring` | Route53 health checks, CloudWatch alarms, SNS topic |

### AWS Resources Not in Terraform

#### Networking (VPCs, Subnets, etc.)

| Resource | Name/ID | Notes |
|----------|---------|-------|
| VPC | `private-infra-vpc` (10.10.100.0/22) | Homelab - migrate |
| Subnets | `private-infra-subnet-*` (4 subnets) | Migrate with VPC |
| IGW | `private-infra-igw` | Migrate with VPC |
| Route Tables | `private-infra-rtb-*` (4 tables) | Migrate with VPC |
| VPC | `public-web-vpc` (10.11.0.0/20) | **Out of scope** - see public-web-infrastructure.md |
| VPC | `default` (172.31.0.0/16) | AWS default - skip |

#### EC2 Instances

| Instance | Type | VPC | Notes |
|----------|------|-----|-------|
| `private-infra_vpn` | t4g.nano | private-infra | WireGuard VPN - migrate |
| `private-infra_dns` | t4g.nano | private-infra | DNS server - migrate |
| `public-web_wordpress_stopthecastle` | t3.micro | public-web | **Out of scope** - see public-web-infrastructure.md |

#### Elastic IPs

| IP | Name | Association | Notes |
|----|------|-------------|-------|
| 44.240.60.80 | `private-infra_vpn_ip` | VPN instance | Migrate |
| 52.40.219.113 | `private-infra_dns_ip` | DNS instance | Migrate |
| 54.149.26.169 | `public-web_wordpresss_castle_ip` | WordPress | **Out of scope** - see public-web-infrastructure.md |
| 35.163.174.186 | (unnamed) | Unattached | Review - possibly unused |
| 52.37.121.19 | (unnamed) | Unattached | Review - possibly unused |

#### Security Groups

| Name | VPC | Notes |
|------|-----|-------|
| `vpn-server_sg` | private-infra | Migrate |
| `private-infra-internal-comms_sg` | private-infra | Migrate |
| `private-infra_alb-public-443` | private-infra | Migrate |
| `allow-ssh_sg` | private-infra | Migrate |
| `dns-server_sg` | private-infra | Migrate |
| `public-web_cloudfront_sg` | public-web | **Out of scope** |
| `public-web_allow-ssh_sg` | public-web | **Out of scope** |

#### Load Balancers

| Name | Type | VPC | Notes |
|------|------|-----|-------|
| `private-infra-alb` | ALB | private-infra | Internet-facing, homelab services - migrate |
| Target Group: `traefik-wind-etherport-net` | HTTPS:443 | | Migrate with ALB |

#### S3 Buckets

| Bucket | Purpose | Notes |
|--------|---------|-------|
| `terraform.wind.etherport.net` | Terraform state | Already used - document only |
| `velero.wind.etherport.net` | Kubernetes backups | Homelab - migrate |
| `archive.wind.etherport.net` | Snapshot archives | Homelab - migrate |
| `archive-test.wind.etherport.net` | Test bucket | Review - migrate or delete |
| `logs.archive.wind.etherport.net` | Archive logs | Homelab - migrate |
| `email-fwd.grahamsmith.net` | Email forwarding | Homelab - migrate |
| `backup.grahamsmith.net` | Backups | Review purpose - likely homelab |
| `logs.grahamsmith.net` | General logs | Homelab - migrate |
| `cflogs.grahamsmith.net` | CloudFront logs | **Out of scope** - campaign CDN logs |
| `smithforsb.com` | Static website | **Out of scope** - campaign site |
| `static.stopthecastle.com` | Static assets | **Out of scope** - campaign assets |

#### Route53 Hosted Zones

| Zone | Type | Notes |
|------|------|-------|
| `etherport.net` | Public | Primary homelab domain - migrate |
| `grahamsmith.net` | Public | Personal domain - migrate |
| `stopthecastle.com` | Public | **Out of scope** - campaign site |
| `smithforsb.com` | Public | **Out of scope** - campaign site |

#### CloudFront Distributions

| ID | Origin | Notes |
|----|--------|-------|
| `E1877NKA6OHGR2` | smithforsb.com S3 | **Out of scope** - campaign site |
| `EGLD2S71PI0A` | static.stopthecastle.com S3 | **Out of scope** - campaign assets |

#### ACM Certificates

**us-west-2 (ALB):**
| Domain | Notes |
|--------|-------|
| `*.wind.etherport.net` | Homelab services - migrate |
| `ha.wind.etherport.net` | Home Assistant - migrate |
| `*.etherport.net` | Wildcard - migrate |
| `*.grahamsmith.net` | Personal - migrate |
| `*.gmsmeg.net` | Legacy? - review |
| `ha.wind.gmsmeg.net` | Legacy? - review |

**us-east-1 (CloudFront):**
| Domain | Notes |
|--------|-------|
| `smithforsb.com` | **Out of scope** - campaign |
| `stopthecastle.com` | **Out of scope** - campaign |
| `smith4sb.com` | **Out of scope** - campaign |
| `ha.wind.gmsmeg.net` | Legacy? - review |

#### IAM Roles (Lambda)

| Role | Purpose | Notes |
|------|---------|-------|
| `ddns-lambda-role` | DDNS Lambda | Already in TF |
| `dns-restrict-ip-lambda-role` | DNS restrict Lambda | Already in TF |
| `email-forward-lambda-role` | Email fwd Lambda | Already in TF |
| `snapshot-archive-lambda-role` | Snapshot Lambda | Already in TF |
| `homeassistant-alexa-lambda-role` | HA Alexa Lambda | Already in TF |
| `email-fwd_grahamsmith-role-*` | Legacy role | Review - may be orphaned |
| `snapshot_archive-role-*` | Legacy role | Review - may be orphaned |

#### DynamoDB Tables

| Table | Purpose | Notes |
|-------|---------|-------|
| `homelab-terraform-locks` | Terraform locking | **Delete** - redundant, using S3 native locking |
| `DataSyncStatus` | DataSync tracking | **Delete** - DataSync deprecated, replaced by custom S3 sync |

#### EventBridge Rules

| Rule | Schedule | Notes |
|------|----------|-------|
| `dns-restrict-ip-schedule` | Every 5 min | Already in TF |
| `DNS_SG_update_5-min` | Every 5 min | Legacy duplicate? Review |
| `snapshot-archive-daily` | Daily 1pm UTC | Already in TF |

#### CloudWatch Log Groups

| Log Group | Retention | Notes |
|-----------|-----------|-------|
| `/aws/lambda/ddns-updater` | 30 days | TF managed |
| `/aws/lambda/dns-restrict-ip` | 30 days | TF managed |
| `/aws/lambda/email-forward` | 30 days | TF managed |
| `/aws/lambda/snapshot-archive` | 30 days | TF managed |
| `/aws/apigateway/ddns-api` | 30 days | TF managed |
| `/aws/lambda/dns_restrict_ip` | 7 days | Legacy - review |
| `/aws/lambda/email-fwd_grahamsmith` | 30 days | Legacy - review |
| `/aws/lambda/snapshot_archive` | 30 days | Legacy - review |
| `/aws/lambda/datasync_status_email` | 30 days | **Delete** - DataSync deprecated |
| `/aws/datasync` | 90 days | **Delete** - DataSync deprecated |
| `aws-waf-logs-alb` | 30 days | WAF logs - migrate |

#### CloudWatch Alarms

**us-west-2:**
| Alarm | Metric | Notes |
|-------|--------|-------|
| `High-Memory-Utilization-DNS` | mem_used_percent | EC2 - migrate |
| `High-Memory-Utilization-VPN` | mem_used_percent | EC2 - migrate |
| `High-Swap-Utilization-DNS` | swap_used_percent | EC2 - migrate |
| `High-Swap-Utilization-VPN` | swap_used_percent | EC2 - migrate |
| `TargetTracking-table/DataSyncStatus-*` | DynamoDB autoscaling | **Delete** - will be removed with DataSyncStatus table |

**us-east-1:**
| Alarm | Notes |
|-------|-------|
| `homelab-*-unhealthy` | TF managed (external-monitoring) |

#### SNS Topics

| Topic | Region | Notes |
|-------|--------|-------|
| `CloudWatch_Alarms_EC2_Low_memory` | us-west-2 | EC2 alerts - migrate |
| `homelab-external-monitoring-alerts` | us-east-1 | TF managed |

#### SES Identities

| Identity | Type | Notes |
|----------|------|-------|
| `etherport.net` | Domain | Homelab email - migrate |
| `grahamsmith.net` | Domain | Personal email - migrate |
| `g@grahamsmith.net` | Email | Personal - migrate |
| `grahamsm@gmail.com` | Email | Personal - migrate |
| `graham.m.smith@me.com` | Email | Personal - migrate |
| `stopthecastle.com` | Domain | **Out of scope** - campaign |
| `smithforsb.com` | Domain | **Out of scope** - campaign |
| `mgoodwin.us@gmail.com` | Email | **Out of scope** - campaign contact |

#### WAF

| WebACL | Scope | Notes |
|--------|-------|-------|
| `CreatedByALB-private-infra-alb` | Regional | Auto-created by ALB - review |

#### Secrets Manager

| Secret | Notes |
|--------|-------|
| `ddns-api-key` | TF managed |

---

## Migration Priority

### Phase 1: Foundation (VPCs & Networking) ✅ COMPLETE
1. ✅ Create `networking` module
2. ✅ Import `private-infra-vpc` (10.10.100.0/22) with IPv6
3. ✅ Import subnets (4), route tables (4), internet gateway, S3 VPC endpoint
4. ✅ Import security groups (6) and all security group rules (22)
5. ✅ Import default NACL with custom rules

**Module:** `infra/terraform/aws/networking/`
**State:** `terraform.wind.etherport.net/aws/networking/terraform.tfstate`

### Phase 2: Compute ✅ COMPLETE
1. ✅ Create `compute` module
2. ✅ Import EC2 instances: `private-infra_vpn`, `private-infra_dns`
3. ✅ Import Elastic IPs (2 attached)
4. ✅ Import CloudWatch alarms for EC2 memory/swap
5. ✅ Import IAM role/instance profile, SNS topic

**Module:** `infra/terraform/aws/compute/`
**State:** `terraform.wind.etherport.net/aws/compute/terraform.tfstate`
**Note:** DLM policy managed outside Terraform (SIMPLIFIED format)

### Phase 3: Load Balancing ✅ COMPLETE
1. ✅ Create `load-balancing` module
2. ✅ Import `private-infra-alb`, listeners, target groups
3. ✅ Import listener certificates (SNI)
4. ✅ Clean up deprecated gmsmeg.net certificates

**Module:** `infra/terraform/aws/load-balancing/`
**State:** `terraform.wind.etherport.net/aws/load-balancing/terraform.tfstate`

### Phase 4: DNS & Certificates ✅ COMPLETE
1. ✅ Create `route53` module
2. ✅ Import hosted zones: `etherport.net`, `grahamsmith.net`
3. ✅ Import DNS records (static infrastructure and email records)
4. ✅ Create `acm` module
5. ✅ Import us-west-2 certificates (4 homelab wildcards)

**Modules:** `infra/terraform/aws/route53/`, `infra/terraform/aws/acm/`
**State:** `terraform.wind.etherport.net/aws/route53/terraform.tfstate`, `terraform.wind.etherport.net/aws/acm/terraform.tfstate`
**Note:** DDNS records (wan1, wan2, wind) managed by ddns-lambda, not Terraform

### Phase 5: Storage & Email
1. Create `s3` module
2. Import homelab S3 buckets (velero, archive, email-fwd, logs)
3. Configure lifecycle policies
4. Import SES domain identities (etherport.net, grahamsmith.net)
5. Import SES email identities

### Phase 6: Cleanup
1. Review legacy/orphaned IAM roles
2. Review unused EIPs (2 unattached)
3. Remove duplicate EventBridge rules
4. Delete legacy CloudWatch log groups
5. Review legacy ACM certificates (gmsmeg.net)

---

## Out of Scope (Public Web Infrastructure)

The following resources are for the stopthecastle.com/smithforsb.com campaign sites and will be managed in a separate repository. See `docs/planning/public-web-infrastructure.md` for full documentation.

- `public-web-vpc` and all associated networking
- `public-web_wordpress_stopthecastle` EC2 instance
- `public-web_wordpresss_castle_ip` Elastic IP
- `public-web_*` security groups
- `stopthecastle.com` and `smithforsb.com` Route53 hosted zones
- `smithforsb.com` and `static.stopthecastle.com` S3 buckets
- `cflogs.grahamsmith.net` S3 bucket (campaign CDN logs)
- Both CloudFront distributions
- Campaign-related ACM certificates (us-east-1)
- Campaign SES identities (stopthecastle.com, smithforsb.com)

## Resources to Skip

- Default VPC and subnets (AWS default)
- Terraform state bucket (already in use, document only)

## Resources to Delete (Cleanup)

| Resource | Type | Reason |
|----------|------|--------|
| `homelab-terraform-locks` | DynamoDB | Redundant - using S3 native locking |
| `DataSyncStatus` | DynamoDB | Deprecated - replaced by custom S3 sync |
| `/aws/lambda/datasync_status_email` | CloudWatch Logs | DataSync deprecated |
| `/aws/datasync` | CloudWatch Logs | DataSync deprecated |
| `TargetTracking-table/DataSyncStatus-*` | CloudWatch Alarms | Will auto-delete with table |

---

## Import Commands Reference

```bash
# Phase 1: Networking
terraform import aws_vpc.private_infra vpc-0cf7cb3b71fc48958
terraform import aws_security_group.vpn_server sg-08323ff8e98ecb563

# Phase 2: Compute
terraform import aws_instance.vpn i-0f81ff99edc6ede03
terraform import aws_eip.vpn eipalloc-XXXXX

# Phase 4: DNS
terraform import aws_route53_zone.etherport Z03500581XDWV5SKF5PK8

# Phase 5: Storage
terraform import aws_s3_bucket.velero velero.wind.etherport.net
```

---

## Notes

- All resources are in `us-west-2` unless noted otherwise
- CloudFront and some ACM certificates are in `us-east-1` (required by CloudFront)
- Route53 is global but health checks require `us-east-1` for CloudWatch alarms
