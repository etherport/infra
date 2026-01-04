# AWS Infrastructure

## Overview

AWS resources in us-west-2 connected to local homelab via WireGuard VPN. The infrastructure supports:
- Site-to-site VPN connectivity between AWS and homelab
- Public DNS services with dynamic IP updates
- Application Load Balancer forwarding web requests to homelab via VPN
- Email forwarding and notification services
- Terraform state management

## Network Architecture

```
                                   Internet
                                      |
                    +-----------------+------------------+
                    |                 |                  |
                    v                 v                  v
            +---------------+  +-------------+  +---------------+
            | ALB (HTTPS)   |  | DNS Server  |  | VPN Server    |
            | *.wind...     |  | Port 53     |  | Port 51820-21 |
            +-------+-------+  +------+------+  +-------+-------+
                    |                 |                  |
                    |        +--------+--------+         |
                    |        |                 |         |
                    |        v                 v         |
                    |   +--------+      +-----------+    |
                    |   |dns-aws |      | vpn-aws   |<---+
                    |   |10.10.  |      | 10.10.    |
                    |   |100.5   |      | 100.10    |
                    |   +--------+      +-----+-----+
                    |                         |
                    +--------+                | WireGuard Tunnel
                             |                | (wg0: site-to-site)
                             v                v
                    +-----------------------------------------+
                    |     Homelab (10.10.192.0/19)           |
                    |                                         |
                    |   Traefik (10.10.201.70:443)           |
                    |     - Reverse proxy for services        |
                    |     - *.wind.etherport.net             |
                    +-----------------------------------------+
```

## VPC Configuration

### private-infra-vpc

| Property | Value |
|----------|-------|
| VPC ID | `vpc-0cf7cb3b71fc48958` |
| CIDR Block | `10.10.100.0/22` |
| IPv6 CIDR | `2600:1f14:244d:2700::/56` |
| Region | us-west-2 |

### Subnets

| Name | Subnet ID | CIDR | AZ | Type |
|------|-----------|------|----|----- |
| private-infra-subnet-public1-us-west-2a | `subnet-05df0a901053021dd` | 10.10.100.0/25 | us-west-2a | Public |
| private-infra-subnet-public2-us-west-2b | `subnet-08263b4042c6e3b03` | 10.10.100.128/25 | us-west-2b | Public |
| private-infra-subnet-private1-us-west-2a | `subnet-0578f069a3ceff73d` | 10.10.101.0/24 | us-west-2a | Private |
| private-infra-subnet-private2-us-west-2b | `subnet-0f0b317cb9a0c0c33` | 10.10.102.0/24 | us-west-2b | Private |

## EC2 Instances

### private-infra VPC

| Name | Instance ID | Private IP | Public IP | Type | Purpose |
|------|-------------|------------|-----------|------|---------|
| private-infra_vpn | `i-0f81ff99edc6ede03` | 10.10.100.10 | 44.240.60.80 | t4g.nano | WireGuard VPN gateway |
| private-infra_dns | `i-0c49c3c41bd03d618` | 10.10.100.5 | 52.40.219.113 | t4g.nano | Technitium DNS (failover) |

### public-web VPC

| Name | Instance ID | Private IP | Public IP | Type | Purpose |
|------|-------------|------------|-----------|------|---------|
| public-web_wordpress_stopthecastle | `i-0ccff04ab95c0e5ad` | 10.11.0.191 | 54.149.26.169 | t3.micro | WordPress hosting |

## Security Groups

### VPN Server Security Group (`sg-08323ff8e98ecb563`)
**Name:** `vpn-server_sg`

| Direction | Protocol | Port | Source/Dest | Description |
|-----------|----------|------|-------------|-------------|
| Inbound | UDP | 51820-51821 | 0.0.0.0/0 | Public WireGuard VPN access |
| Outbound | All | All | 0.0.0.0/0 | All outbound |

### DNS Server Security Group (`sg-08d12e417159c18d2`)
**Name:** `dns-server_sg`

| Direction | Protocol | Port | Source/Dest | Description |
|-----------|----------|------|-------------|-------------|
| Inbound | UDP | 53 | 47.159.189.230/32 | DNS from restricted IP (dynamic) |
| Inbound | TCP | 53 | 47.159.189.230/32 | DNS (TCP) from restricted IP |
| Inbound | TCP | 443 | pl-82a045eb (CloudFront) | HTTPS from CloudFront |
| Outbound | All | All | 0.0.0.0/0 | All outbound |

**Note:** The restricted IP (47.159.189.230) is dynamically updated by the `dns_restrict_ip` Lambda function based on the `wind.etherport.net` DNS record.

### Internal Communications Security Group (`sg-0c882ffea5692bd63`)
**Name:** `private-infra-internal-comms_sg`

| Direction | Protocol | Port | Source/Dest | Description |
|-----------|----------|------|-------------|-------------|
| Inbound | All | All | 10.10.100.0/22 | VPC resources |
| Inbound | All | All | 10.10.192.0/19 | Homelab (wind) network |
| Inbound | All | All | 10.254.0.0/24 | Remote VPN clients |
| Inbound | All | All | 10.255.255.0/30 | Site-to-site VPN clients |
| Outbound | All | All | 0.0.0.0/0 | All outbound |

### SSH Access Security Group (`sg-0079fee23ee54417a`)
**Name:** `allow-ssh_sg`

| Direction | Protocol | Port | Source/Dest | Description |
|-----------|----------|------|-------------|-------------|
| Inbound | TCP | 22 | 47.159.189.230/32 | SSH from restricted IP |
| Outbound | All | All | 0.0.0.0/0 | All outbound |

### ALB Public HTTPS Security Group (`sg-0a4bebabcd3bd4d20`)
**Name:** `private-infra_alb-public-443`

| Direction | Protocol | Port | Source/Dest | Description |
|-----------|----------|------|-------------|-------------|
| Inbound | TCP | 443 | 0.0.0.0/0 | HTTPS from internet |
| Outbound | All | All | 0.0.0.0/0 | All outbound |

### CloudFront Access Security Group (`sg-09058a7de637a754d`)
**Name:** `public-web_cloudfront_sg` (public-web VPC)

| Direction | Protocol | Port | Source/Dest | Description |
|-----------|----------|------|-------------|-------------|
| Inbound | TCP | 80 | pl-82a045eb (CloudFront) | HTTP from CloudFront |
| Inbound | TCP | 443 | pl-82a045eb (CloudFront) | HTTPS from CloudFront |
| Outbound | All | All | 0.0.0.0/0 | All outbound |

## Network ACLs

### private-infra VPC NACL (`acl-0282c4f7529cdf112`)

**Inbound Rules:**

| Rule | Protocol | Port | Source | Action |
|------|----------|------|--------|--------|
| 100 | TCP | 53 | 0.0.0.0/0 | Allow |
| 102 | UDP | 53 | 0.0.0.0/0 | Allow |
| 104 | TCP | 443 | 0.0.0.0/0 | Allow |
| 106 | UDP | 1194-1195 | 0.0.0.0/0 | Allow |
| 108 | All | All | 10.10.192.0/19 | Allow (homelab) |
| 109 | All | All | 10.8.10.0/24 | Allow |
| 110 | All | All | 10.8.20.0/24 | Allow |
| 111 | All | All | 10.10.100.0/22 | Allow (VPC) |
| 112 | TCP | 22 | 0.0.0.0/0 | Allow |
| 113 | TCP | 1024-65535 | 0.0.0.0/0 | Allow (ephemeral) |
| 115 | UDP | 1024-65535 | 0.0.0.0/0 | Allow (ephemeral) |
| 117 | ICMP | All | 0.0.0.0/0 | Allow |

**Outbound Rules:** Allow all (0.0.0.0/0)

## Application Load Balancer (ALB)

### private-infra-alb

| Property | Value |
|----------|-------|
| ARN | `arn:aws:elasticloadbalancing:us-west-2:830881980142:loadbalancer/app/private-infra-alb/b80aa78d7562bac7` |
| DNS Name | `private-infra-alb-687735217.us-west-2.elb.amazonaws.com` |
| Scheme | internet-facing |
| Type | Application |
| IP Type | dualstack (IPv4 + IPv6) |
| Security Groups | `sg-0a4bebabcd3bd4d20` (HTTPS 443) |
| Availability Zones | us-west-2a, us-west-2b |

### HTTPS Listener (Port 443)

| Property | Value |
|----------|-------|
| SSL Policy | ELBSecurityPolicy-TLS13-1-2-Res-2021-06 |
| Certificate | `arn:aws:acm:us-west-2:830881980142:certificate/bdc9a820-fc67-49ad-98ec-ee18652fe70a` |
| Default Action | Fixed response 503 |

### Listener Rules

| Priority | Condition | Action |
|----------|-----------|--------|
| 100 | Host: `*.wind.etherport.net` | Forward to `traefik-wind-etherport-net` target group |
| default | - | Fixed response 503 |

### Target Group: traefik-wind-etherport-net

| Property | Value |
|----------|-------|
| ARN | `arn:aws:elasticloadbalancing:us-west-2:830881980142:targetgroup/traefik-wind-etherport-net/4d57b4fab3697a62` |
| Protocol | HTTPS |
| Port | 443 |
| Target Type | IP |
| Health Check | HTTPS / (200, 404) |

**Registered Targets:**

| IP Address | Port | Status |
|------------|------|--------|
| 10.10.201.70 | 443 | healthy |

**Note:** Target IP 10.10.201.70 is in the homelab network, reachable via the WireGuard VPN tunnel through vpn-aws.

## Traffic Flow: Internet to Homelab

```
1. Client requests https://plex.wind.etherport.net
2. DNS resolves to ALB: private-infra-alb-687735217.us-west-2.elb.amazonaws.com
3. ALB receives request on port 443
4. WAF inspects request (IP reputation, common rules, bad inputs)
5. ALB matches host header *.wind.etherport.net
6. ALB forwards to target group (10.10.201.70:443)
7. Traffic routed via VPC route table to vpn-aws ENI
8. vpn-aws forwards through WireGuard tunnel (wg0)
9. Arrives at Traefik reverse proxy in homelab
10. Traefik routes to appropriate backend service
```

## WAF Configuration

### Web ACL: CreatedByALB-private-infra-alb

| Property | Value |
|----------|-------|
| ID | `ed2149c5-f335-4c97-9b1a-58d827cb00d9` |
| Default Action | Allow |
| DDoS Protection | Active under DDoS (ALB Low Reputation Mode) |

### WAF Rules (by priority)

| Priority | Rule Name | Type | Action |
|----------|-----------|------|--------|
| 0 | AllowPlexLongURLs | Custom | Allow (bypasses common rules for Plex host header) |
| 1 | AWS-AWSManagedRulesAmazonIpReputationList | AWS Managed | Block bad IPs |
| 2 | AWS-AWSManagedRulesCommonRuleSet | AWS Managed | Common attack patterns |
| 3 | AWS-AWSManagedRulesKnownBadInputsRuleSet | AWS Managed | Known bad inputs (SQLi, XSS, etc.) |

**Custom Rule Details:**
- `AllowPlexLongURLs`: Matches requests where Host header exactly equals `plex.wind.etherport.net` and allows them, bypassing size limits that affect Plex's long URLs.

## Lambda Functions

### dns_restrict_ip (Dynamic DNS Security Group Updater)

| Property | Value |
|----------|-------|
| ARN | `arn:aws:lambda:us-west-2:830881980142:function:dns_restrict_ip` |
| Runtime | Python 3.13 |
| Architecture | arm64 |
| Memory | 128 MB |
| Timeout | 3 seconds |
| Last Modified | 2026-01-03 |

**Purpose:** Updates the DNS server security group to allow access only from the current dynamic IP of the homelab, determined by resolving `wind.etherport.net`.

**Environment Variables:**

| Variable | Value |
|----------|-------|
| HOSTED_ZONE_ID | Z03500581XDWV5SKF5PK8 |
| RECORD_NAME | wind.etherport.net. |
| SECURITY_GROUP_ID | sg-08d12e417159c18d2 |

**Flow:**
1. Triggered on schedule (EventBridge)
2. Resolves `wind.etherport.net` to get current homelab public IP
3. Updates security group `sg-08d12e417159c18d2` to allow DNS access from that IP

### snapshot_archive

| Property | Value |
|----------|-------|
| ARN | `arn:aws:lambda:us-west-2:830881980142:function:snapshot_archive` |
| Runtime | Python 3.13 |
| Architecture | arm64 |
| Memory | 128 MB |
| Timeout | 10 seconds |

**Purpose:** Archives EC2 snapshots and sends summary emails via SES.

### datasync_status_email

| Property | Value |
|----------|-------|
| ARN | `arn:aws:lambda:us-west-2:830881980142:function:datasync_status_email` |
| Runtime | Python 3.13 |
| Architecture | arm64 |
| Memory | 256 MB |
| Timeout | 60 seconds |

**Purpose:** Sends daily DataSync status update emails via SES.

### email-fwd_grahamsmith

| Property | Value |
|----------|-------|
| ARN | `arn:aws:lambda:us-west-2:830881980142:function:email-fwd_grahamsmith` |
| Runtime | Python 3.13 |
| Architecture | arm64 |
| Memory | 128 MB |
| Timeout | 3 seconds |

**Purpose:** Forwards emails received by SES to personal email addresses.

## DynamoDB Tables

### homelab-terraform-locks

| Property | Value |
|----------|-------|
| ARN | `arn:aws:dynamodb:us-west-2:830881980142:table/homelab-terraform-locks` |
| Billing Mode | PAY_PER_REQUEST (on-demand) |
| Primary Key | LockID (String) |
| Status | ACTIVE |

**Purpose:** Terraform state locking for concurrent operations.

### DataSyncStatus

| Property | Value |
|----------|-------|
| ARN | `arn:aws:dynamodb:us-west-2:830881980142:table/DataSyncStatus` |
| Billing Mode | Provisioned (1 RCU / 1 WCU) |
| Primary Key | TaskID (String) |
| Status | ACTIVE |

**Purpose:** Tracks DataSync task status for the datasync_status_email Lambda.

## VPC Route Table

| Destination | Target | Notes |
|-------------|--------|-------|
| 10.10.100.0/22 | local | VPC local |
| 0.0.0.0/0 | igw-xxx | Internet gateway |
| 10.10.192.0/19 | eni-xxx (vpn-aws) | Route to homelab via VPN |

**Note:** The route to 10.10.192.0/19 must point to the vpn-aws instance's ENI with source/dest check disabled.

## IAM Configuration

### EC2 Instance Profile

Both vpn-aws and dns-aws use the IAM instance profile:
- `arn:aws:iam::830881980142:instance-profile/EC2-role_udpate_route53_gmsmeg.net`

This allows Route53 updates for dynamic DNS.

### Required IAM Policy for Infrastructure Review

Create a policy with read-only access for documentation/audit purposes:

```json
{
    "Version": "2012-10-17",
    "PolicyName": "HomelabInfraReadOnly",
    "Statement": [
        {
            "Sid": "EC2ReadOnly",
            "Effect": "Allow",
            "Action": [
                "ec2:Describe*",
                "ec2:Get*"
            ],
            "Resource": "*"
        },
        {
            "Sid": "VPCReadOnly",
            "Effect": "Allow",
            "Action": [
                "ec2:DescribeVpcs",
                "ec2:DescribeSubnets",
                "ec2:DescribeRouteTables",
                "ec2:DescribeSecurityGroups",
                "ec2:DescribeSecurityGroupRules",
                "ec2:DescribeNetworkAcls",
                "ec2:DescribeInternetGateways",
                "ec2:DescribeNatGateways"
            ],
            "Resource": "*"
        },
        {
            "Sid": "LambdaReadOnly",
            "Effect": "Allow",
            "Action": [
                "lambda:ListFunctions",
                "lambda:GetFunction",
                "lambda:GetFunctionConfiguration"
            ],
            "Resource": "*"
        },
        {
            "Sid": "ELBReadOnly",
            "Effect": "Allow",
            "Action": [
                "elasticloadbalancing:Describe*"
            ],
            "Resource": "*"
        },
        {
            "Sid": "WAFReadOnly",
            "Effect": "Allow",
            "Action": [
                "wafv2:List*",
                "wafv2:Get*"
            ],
            "Resource": "*"
        },
        {
            "Sid": "DynamoDBReadOnly",
            "Effect": "Allow",
            "Action": [
                "dynamodb:ListTables",
                "dynamodb:DescribeTable"
            ],
            "Resource": "*"
        },
        {
            "Sid": "IAMReadOnly",
            "Effect": "Allow",
            "Action": [
                "iam:GetUser",
                "iam:GetRole",
                "iam:GetPolicy",
                "iam:ListUsers",
                "iam:ListRoles",
                "iam:ListPolicies",
                "iam:ListAttachedUserPolicies",
                "iam:ListAttachedRolePolicies"
            ],
            "Resource": "*"
        },
        {
            "Sid": "Route53ReadOnly",
            "Effect": "Allow",
            "Action": [
                "route53:Get*",
                "route53:List*"
            ],
            "Resource": "*"
        },
        {
            "Sid": "S3ReadOnly",
            "Effect": "Allow",
            "Action": [
                "s3:GetBucketLocation",
                "s3:GetBucketPolicy",
                "s3:GetBucketAcl",
                "s3:ListBucket",
                "s3:ListAllMyBuckets"
            ],
            "Resource": "*"
        },
        {
            "Sid": "CloudWatchReadOnly",
            "Effect": "Allow",
            "Action": [
                "cloudwatch:Describe*",
                "cloudwatch:Get*",
                "cloudwatch:List*",
                "logs:Describe*",
                "logs:Get*"
            ],
            "Resource": "*"
        },
        {
            "Sid": "STSGetCallerIdentity",
            "Effect": "Allow",
            "Action": "sts:GetCallerIdentity",
            "Resource": "*"
        }
    ]
}
```

## Services Running

### vpn-aws

| Service | Status | Description |
|---------|--------|-------------|
| wg-quick@wg0 | enabled | Site-to-site VPN to homelab |
| wg-quick@wg1 | enabled | Remote access VPN for mobile |

### dns-aws

| Service | Status | Description |
|---------|--------|-------------|
| technitium | enabled | Technitium DNS Server |

## Ansible Management

AWS instances are managed via Ansible from the local workstation over the WireGuard VPN:

```bash
# Base system configuration (unattended-upgrades, NTP, etc.)
cd infra/ansible
ansible-playbook -i inventory/aws/ playbooks/base.yml

# WireGuard VPN configuration
ansible-playbook -i inventory/aws/ playbooks/wireguard.yml

# Technitium DNS Server
ansible-playbook -i inventory/aws/ playbooks/technitium.yml

# Ping test
ansible -i inventory/aws/ all -m ping

# Check mode (dry-run)
ansible-playbook -i inventory/aws/ playbooks/base.yml --check --diff
```

### Available Playbooks

| Playbook | Purpose |
|----------|---------|
| base.yml | System config: timezone, NTP, unattended-upgrades, SSH hardening |
| wireguard.yml | WireGuard VPN configuration (vpn-aws only) |
| technitium.yml | Technitium DNS Server installation (dns-aws only) |

### Inventory Structure

```
infra/ansible/inventory/aws/
  inventory.ini          # Host definitions
  group_vars/
    all/                 # Variables for all AWS hosts
```

## Connectivity Requirements

1. **WireGuard VPN must be up** - All management traffic flows over VPN
2. **SSH via VPN** - No public SSH access, use VPN tunnel
3. **DNS via VPN** - dns-aws only accessible from VPN networks

## Cost Optimization

- Using Graviton (ARM64) instances for ~20% cost savings
- t4g.nano for VPN and DNS (minimal CPU)
- t3.micro for WordPress
- No NAT Gateway (using Internet Gateway + public IP for VPN)
- DynamoDB on-demand billing for Terraform locks
- Lambda on ARM64 architecture

## Backup Strategy

- Configuration files in Git (this repo)
- WireGuard keys in 1Password
- Technitium zones synced via GitOps from YAML files
- EC2 snapshots managed by DLM policy and snapshot_archive Lambda

## AWS CLI Access

The `homelab-review` IAM user has read-only permissions for infrastructure auditing.

**Current status (as of 2026-01-04):**
```
aws --profile homelab-review sts get-caller-identity
Account: 830881980142
```
