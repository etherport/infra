# AWS Infrastructure Terraform Migration Plan

## Overview

This document outlines the plan to migrate existing AWS resources into Terraform management.

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
| VPC | `public-web-vpc` (10.11.0.0/20) | Homelab - migrate |
| VPC | `default` (172.31.0.0/16) | AWS default - skip |
| Subnets | `private-infra-subnet-*` (4 subnets) | Migrate with VPC |
| Subnets | `public-web-subnet-*` (4 subnets) | Migrate with VPC |
| IGW | `private-infra-igw` | Migrate with VPC |
| IGW | `public-web-igw` | Migrate with VPC |
| Route Tables | `private-infra-rtb-*` (4 tables) | Migrate with VPC |
| Route Tables | `public-web-rtb-*` (4 tables) | Migrate with VPC |

#### EC2 Instances

| Instance | Type | VPC | Notes |
|----------|------|-----|-------|
| `private-infra_vpn` | t4g.nano | private-infra | WireGuard VPN - migrate |
| `private-infra_dns` | t4g.nano | private-infra | DNS server - migrate |
| `public-web_wordpress_stopthecastle` | t3.micro | public-web | WordPress site - migrate |

#### Elastic IPs

| IP | Name | Association | Notes |
|----|------|-------------|-------|
| 44.240.60.80 | `private-infra_vpn_ip` | VPN instance | Migrate |
| 52.40.219.113 | `private-infra_dns_ip` | DNS instance | Migrate |
| 54.149.26.169 | `public-web_wordpresss_castle_ip` | WordPress | Migrate |
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
| `public-web_cloudfront_sg` | public-web | Migrate |
| `public-web_allow-ssh_sg` | public-web | Migrate |

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
| `archive-test.wind.etherport.net` | Test bucket | Homelab - migrate or delete |
| `logs.archive.wind.etherport.net` | Archive logs | Homelab - migrate |
| `email-fwd.grahamsmith.net` | Email forwarding | Homelab - migrate |
| `backup.grahamsmith.net` | Backups | Review purpose |
| `cflogs.grahamsmith.net` | CloudFront logs | Migrate |
| `logs.grahamsmith.net` | General logs | Migrate |
| `smithforsb.com` | Static website | Campaign site - migrate |
| `static.stopthecastle.com` | Static assets | WordPress assets - migrate |

#### Route53 Hosted Zones

| Zone | Type | Notes |
|------|------|-------|
| `etherport.net` | Public | Primary homelab domain - migrate |
| `grahamsmith.net` | Public | Personal domain - migrate |
| `stopthecastle.com` | Public | Campaign site - migrate |
| `smithforsb.com` | Public | Campaign site - migrate |

#### CloudFront Distributions

| ID | Origin | Notes |
|----|--------|-------|
| `E1877NKA6OHGR2` | smithforsb.com S3 | Campaign site - migrate |
| `EGLD2S71PI0A` | static.stopthecastle.com S3 | WordPress assets - migrate |

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
| `smithforsb.com` | Campaign - migrate |
| `stopthecastle.com` | Campaign - migrate |
| `smith4sb.com` | Alternate domain - migrate |
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
| `homelab-terraform-locks` | Terraform locking | Document only |
| `DataSyncStatus` | DataSync tracking | Migrate |

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
| `/aws/lambda/datasync_status_email` | 30 days | Not in TF - migrate |
| `/aws/datasync` | 90 days | DataSync logs - migrate |
| `aws-waf-logs-alb` | 30 days | WAF logs - migrate |

#### CloudWatch Alarms

**us-west-2:**
| Alarm | Metric | Notes |
|-------|--------|-------|
| `High-Memory-Utilization-DNS` | mem_used_percent | EC2 - migrate |
| `High-Memory-Utilization-VPN` | mem_used_percent | EC2 - migrate |
| `High-Swap-Utilization-DNS` | swap_used_percent | EC2 - migrate |
| `High-Swap-Utilization-VPN` | swap_used_percent | EC2 - migrate |
| `TargetTracking-table/DataSyncStatus-*` | DynamoDB autoscaling | Auto-created - skip |

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
| `etherport.net` | Domain | Email - migrate |
| `grahamsmith.net` | Domain | Email - migrate |
| `stopthecastle.com` | Domain | Email - migrate |
| `smithforsb.com` | Domain | Email - migrate |
| `g@grahamsmith.net` | Email | Personal - migrate |
| `grahamsm@gmail.com` | Email | Personal - migrate |
| `mgoodwin.us@gmail.com` | Email | Contact - migrate |
| `graham.m.smith@me.com` | Email | Personal - migrate |

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

### Phase 1: Foundation (VPCs & Networking)
1. Create `networking` module
2. Import VPCs: `private-infra-vpc`, `public-web-vpc`
3. Import subnets, route tables, internet gateways
4. Import security groups

### Phase 2: Compute
1. Create `ec2` module
2. Import EC2 instances (VPN, DNS, WordPress)
3. Import Elastic IPs
4. Import CloudWatch alarms for EC2

### Phase 3: Load Balancing
1. Create `alb` module
2. Import ALB, listeners, target groups
3. Import WAF WebACL

### Phase 4: DNS & Certificates
1. Create `route53` module
2. Import hosted zones
3. Import DNS records
4. Create `acm` module
5. Import certificates

### Phase 5: Storage
1. Create `s3` module
2. Import S3 buckets
3. Configure lifecycle policies

### Phase 6: CDN
1. Create `cloudfront` module
2. Import distributions

### Phase 7: Cleanup
1. Review legacy/orphaned resources
2. Clean up unused EIPs
3. Remove duplicate EventBridge rules
4. Delete legacy log groups

---

## Resources to Skip

- Default VPC and subnets (AWS default)
- DynamoDB autoscaling alarms (auto-managed)
- Terraform state bucket (already in use, document only)
- Terraform locks table (already in use, document only)

---

## Import Commands Reference

```bash
# VPC import example
terraform import aws_vpc.private_infra vpc-0cf7cb3b71fc48958

# EC2 import example
terraform import aws_instance.vpn i-0f81ff99edc6ede03

# Security group import example
terraform import aws_security_group.vpn_server sg-08323ff8e98ecb563

# S3 bucket import example
terraform import aws_s3_bucket.velero velero.wind.etherport.net

# Route53 zone import example
terraform import aws_route53_zone.etherport Z03500581XDWV5SKF5PK8
```

---

## Notes

- All resources are in `us-west-2` unless noted otherwise
- CloudFront and some ACM certificates are in `us-east-1` (required by CloudFront)
- Route53 is global but health checks require `us-east-1` for CloudWatch alarms
