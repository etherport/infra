# AWS Infrastructure

## Overview

AWS resources in us-west-2 connected to local homelab via WireGuard VPN.

## Network Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         AWS VPC (us-west-2)                                 │
│                         CIDR: 10.10.100.0/24                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   ┌─────────────────┐         ┌─────────────────┐                          │
│   │  vpn-aws        │         │  dns-aws        │                          │
│   │  10.10.100.10   │         │  10.10.100.5    │                          │
│   │                 │         │                 │                          │
│   │  WireGuard      │         │  Technitium     │                          │
│   │  - wg0: site VPN│         │  DNS Server     │                          │
│   │  - wg1: remote  │         │                 │                          │
│   │                 │         │                 │                          │
│   │  Public IP:     │         │                 │                          │
│   │  44.240.60.80   │         │                 │                          │
│   └────────┬────────┘         └─────────────────┘                          │
│            │                                                                │
│            │  WireGuard Tunnel                                              │
│            │  to local: 10.10.201.15                                        │
│            ▼                                                                │
│   ┌─────────────────────────────────────────────────────────────┐          │
│   │              Internet Gateway                                │          │
│   └─────────────────────────────────────────────────────────────┘          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## EC2 Instances

| Name | Private IP | Public IP | Instance Type | OS | Purpose |
|------|------------|-----------|---------------|-----|---------|
| vpn-aws | 10.10.100.10 | 44.240.60.80 | t4g.nano | Ubuntu 24.04 ARM64 | WireGuard VPN gateway |
| dns-aws | 10.10.100.5 | (none) | t4g.micro | Ubuntu 24.04 ARM64 | Technitium DNS (failover) |

## Required Security Group Rules

### vpn-aws Security Group

| Type | Protocol | Port | Source | Description |
|------|----------|------|--------|-------------|
| Inbound | UDP | 51820 | 0.0.0.0/0 | WireGuard site-to-site (wg0) |
| Inbound | UDP | 51821 | 0.0.0.0/0 | WireGuard remote access (wg1) |
| Inbound | TCP | 22 | 10.10.0.0/16 | SSH from VPN |
| Outbound | All | All | 0.0.0.0/0 | All outbound |

### dns-aws Security Group

| Type | Protocol | Port | Source | Description |
|------|----------|------|--------|-------------|
| Inbound | UDP | 53 | 10.10.0.0/16 | DNS from VPN networks |
| Inbound | TCP | 53 | 10.10.0.0/16 | DNS (TCP) from VPN |
| Inbound | TCP | 5380 | 10.10.0.0/16 | Technitium web UI |
| Inbound | TCP | 22 | 10.10.0.0/16 | SSH from VPN |
| Outbound | All | All | 0.0.0.0/0 | All outbound |

## VPC Route Table

| Destination | Target | Notes |
|-------------|--------|-------|
| 10.10.100.0/24 | local | VPC local |
| 0.0.0.0/0 | igw-xxx | Internet gateway |
| 10.10.192.0/19 | eni-xxx (vpn-aws) | Route to homelab via VPN |

**Note:** The route to 10.10.192.0/19 must point to the vpn-aws instance's ENI with source/dest check disabled.

## IAM Configuration

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

Attach this policy to the `terraform-homelab` user for infrastructure auditing.

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

AWS instances are managed via Ansible from the local workstation:

```bash
# Target only AWS hosts
ansible-playbook -i inventory/aws/ playbooks/technitium.yml

# Or specific host
ansible -i inventory/aws/ dns-aws -m ping
```

## Connectivity Requirements

1. **WireGuard VPN must be up** - All management traffic flows over VPN
2. **SSH via VPN** - No public SSH access, use VPN tunnel
3. **DNS via VPN** - dns-aws only accessible from VPN networks

## Cost Optimization

- Using Graviton (ARM64) instances for ~20% cost savings
- t4g.nano for VPN (minimal CPU)
- t4g.micro for DNS (slightly more headroom)
- No NAT Gateway (using Internet Gateway + public IP for VPN)

## Backup Strategy

- Configuration files in Git (this repo)
- WireGuard keys in 1Password
- Technitium zones synced via GitOps from YAML files

## TODO

- [ ] Document actual Security Group IDs
- [ ] Document VPC ID and Subnet IDs
- [ ] Set up CloudWatch monitoring
- [ ] Consider Terraform for AWS infrastructure
