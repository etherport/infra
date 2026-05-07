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

| Name | Instance ID | Private IP | Public IP | Type | Purpose |
|------|-------------|------------|-----------|------|---------|
| private-infra_vpn | `i-011086cefc7ab3cc1` | 10.10.100.10 | 44.240.60.80 | t4g.nano | WireGuard VPN gateway |
| private-infra_dns | `i-050de21bdad2603bb` | 10.10.100.5 | 52.40.219.113 | t4g.nano | Technitium DNS (failover) |

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
| Inbound | All | All | 10.255.255.0/29 | Site-to-site VPN clients |
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

All Lambda functions are managed via Terraform modules in `infra/terraform/aws/`.

### dns-restrict-ip

| Property | Value |
|----------|-------|
| Function Name | `dns-restrict-ip` |
| Runtime | Python 3.13 |
| Architecture | arm64 |
| Memory | 128 MB |
| Timeout | 3 seconds |
| Terraform Module | `infra/terraform/aws/dns-restrict-ip/` |

**Purpose:** Updates the DNS server security group to allow access only from the current dynamic IP of the homelab, determined by resolving `wind.etherport.net`.

**Flow:**
1. Triggered every 5 minutes (EventBridge)
2. Resolves `wind.etherport.net` to get current homelab public IP
3. Updates security group `sg-08d12e417159c18d2` to allow DNS access from that IP

### ddns-updater

| Property | Value |
|----------|-------|
| Function Name | `ddns-updater` |
| Runtime | Python 3.13 |
| Architecture | arm64 |
| Memory | 128 MB |
| Timeout | 10 seconds |
| Terraform Module | `infra/terraform/aws/ddns-lambda/` |

**Purpose:** Updates Route53 DNS records with current public IP. Called via API Gateway from Ubiquiti UDM-Pro DDNS client.

### email-forward

| Property | Value |
|----------|-------|
| Function Name | `email-forward` |
| Runtime | Python 3.13 |
| Architecture | arm64 |
| Memory | 128 MB |
| Timeout | 30 seconds |
| Terraform Module | `infra/terraform/aws/email-forward/` |

**Purpose:** Forwards emails received by SES to personal email addresses. Supports forwarding from grahamsmith.net, etherport.net, and campaign domains.

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
- `arn:aws:iam::830881980142:instance-profile/ec2-cloudwatch-agent`

This allows the CloudWatch agent to publish metrics and logs.

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
- No NAT Gateway (using Internet Gateway + public IP for VPN)
- DynamoDB on-demand billing for Terraform locks
- Lambda on ARM64 architecture

## Backup Strategy

- Configuration files in Git (this repo)
- WireGuard keys in 1Password
- Technitium zones synced via GitOps from YAML files
- **EC2 instances are disposable** - no snapshots needed (Terraform + Ansible can recreate)

## External Monitoring

### Route53 Health Checks

External monitoring from AWS edge locations to detect homelab outages.

| Endpoint | FQDN | Health Check Path | Status |
|----------|------|-------------------|--------|
| Home Assistant | ha.wind.etherport.net | / | Enabled |
| Plex | plex.wind.etherport.net | /identity | Enabled |
| Chat (Open WebUI) | chat.wind.etherport.net | / | Enabled |
| Grafana | grafana.wind.etherport.net | /api/health | Disabled (ALB issue) |
| Traefik | traefik.wind.etherport.net | /ping | Disabled (ALB issue) |
| Kopia | kopia.wind.etherport.net | / | Disabled (ALB issue) |

**Configuration:**
- Checks from 3 regions: us-west-2, us-east-1, eu-west-1
- Failure threshold: 2-3 consecutive failures
- Check interval: 30 seconds

### CloudWatch Alarms

Each health check has a corresponding CloudWatch alarm in us-east-1:
- Individual alarms: `homelab-<endpoint>-unhealthy`
- Composite alarm: `homelab-any-endpoint-unhealthy`

### SNS Notifications

**Topic:** `arn:aws:sns:us-east-1:830881980142:homelab-external-monitoring-alerts`

**Subscriptions:**
- graham.m.smith@me.com (primary)
- grahamsm@gmail.com (backup)

**Note:** The SNS topic policy explicitly allows CloudWatch to publish alarm notifications.

### Terraform Management

External monitoring is managed via Terraform:
```
infra/terraform/aws/external-monitoring/
├── main.tf           # Health checks, alarms, SNS
├── variables.tf      # Endpoint configuration schema
├── terraform.tfvars  # Endpoint definitions
└── outputs.tf        # Health check IDs
```

## Terraform Infrastructure Modules

All AWS infrastructure is now managed via Terraform. See `infra/terraform/aws/MIGRATION_PLAN.md` for full details.

### Module Overview

| Module | State File | Resources Managed |
|--------|------------|-------------------|
| `networking/` | `aws/networking/terraform.tfstate` | VPC, subnets, route tables, IGW, security groups, NACLs |
| `compute/` | `aws/compute/terraform.tfstate` | EC2 instances, EIPs, IAM roles, CloudWatch alarms, SNS |
| `load-balancing/` | `aws/load-balancing/terraform.tfstate` | ALB, listeners, target groups, certificates |
| `route53/` | `aws/route53/terraform.tfstate` | Hosted zones (etherport.net, grahamsmith.net), DNS records |
| `acm/` | `aws/acm/terraform.tfstate` | SSL/TLS certificates (us-west-2) |
| `s3/` | `aws/s3/terraform.tfstate` | S3 buckets (velero, archive, logs, email-fwd) |
| `ses/` | `aws/ses/terraform.tfstate` | SES domain/email identities, DKIM |

### Lambda Modules

| Module | State File | Purpose |
|--------|------------|---------|
| `ddns-lambda/` | `aws/ddns-lambda/terraform.tfstate` | Dynamic DNS updater (API Gateway + Lambda) |
| `dns-restrict-ip/` | `aws/dns-restrict-ip/terraform.tfstate` | DNS security group IP updater |
| `email-forward/` | `aws/email-forward/terraform.tfstate` | SES email forwarding |
| `homeassistant-alexa/` | `aws/homeassistant-alexa/terraform.tfstate` | Home Assistant Alexa integration |
| `external-monitoring/` | `aws/external-monitoring/terraform.tfstate` | Route53 health checks and alerting |

### State Backend

All Terraform state is stored in S3 with native S3 locking:
- **Bucket:** `terraform.wind.etherport.net`
- **Region:** us-west-2
- **Path:** `aws/<module>/terraform.tfstate`

## AWS CLI Access

### IAM Users

| User | Purpose | Profile |
|------|---------|---------|
| terraform-homelab | Terraform operations | homelab |
| homelab-review | Read-only infrastructure audit | homelab-review |
| claude-admin | AI assistant infrastructure access | homelab |

**Current status (as of 2026-04-10):**
```
aws --profile homelab sts get-caller-identity
Account: 830881980142
```

## Resources Not in Terraform

The following resources exist but are managed manually or by other means:

- **WAF WebACL:** `CreatedByALB-private-infra-alb` - Auto-created by ALB, managed via AWS Console
- **Key Pairs:** `GS-EC2`, `Wordpress-key` - Created manually, private keys in 1Password

## Out of Scope (Public Web Infrastructure)

The following resources are for the stopthecastle.com/smithforsb.com campaign sites and are documented separately in `docs/planning/public-web-infrastructure.md`:

- `public-web-vpc` and all associated networking
- `public-web_wordpress_stopthecastle` EC2 instance
- CloudFront distributions
- Campaign S3 buckets and ACM certificates (us-east-1)
