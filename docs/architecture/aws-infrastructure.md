# AWS Infrastructure

## Overview

AWS resources in us-west-2 connected to local homelab via WireGuard VPN. The infrastructure supports:
- Site-to-site VPN connectivity between AWS and homelab
- Public DNS services with dynamic IP updates
- Email forwarding and notification services
- External monitoring (Route53 health checks → SNS)
- Terraform state management

**No ALB — the public edge is the Cloudflare Tunnel** (`infra/terraform/cloudflare/main.tf`);
AWS holds no public HTTPS entry point for `*.wind.etherport.net`. See
[Migration history](#migration-history).

## Network Architecture

```
                                   Internet
                                      |
                    +-----------------+------------------+
                    |                                    |
                    v                                    v
              +-------------+                  +---------------+
              | DNS Server  |                  | VPN Server    |
              | Port 53     |                  | Port 51820-21 |
              +------+------+                  +-------+-------+
                     |                                  |
                     v                                  v
                +--------+                       +-----------+
                |dns-aws |                       | vpn-aws   |
                |10.10.  |                       | 10.10.    |
                |100.5   |                       | 100.10    |
                +--------+                       +-----+-----+
                                                       |
                    +--------+                         | WireGuard Tunnel
                             |                         | (wg0: site-to-site)
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
| private-infra_edge | `i-011086cefc7ab3cc1` | 10.10.100.10 | 44.240.60.80 | t4g.small | Multi-service edge box (hostname `vpn-aws`): WireGuard VPN gateway; renamed from `private-infra_vpn` + resized from t4g.nano 2026-07-01 (M110) |
| private-infra_dns | `i-050de21bdad2603bb` | 10.10.100.5 | 52.40.219.113 | t4g.nano | Technitium DNS (failover, hostname `dns-aws`) |

> **🟡 M110 consolidation in progress (2026-07):** Technitium DNS is being folded onto
> the `private-infra_edge` box; `private-infra_dns` will then be **destroyed** and its
> EIP `52.40.219.113` released. Update this table (and every `10.10.100.5` /
> `52.40.219.113` reference) when that lands — see M110 in
> `docs/planning/outstanding-work.md`.

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
| Inbound | All | All | spoke VPCs (peered CIDRs) | AWS spoke VPCs reachable through this VPC (commit 8764631) |
| Outbound | All | All | 0.0.0.0/0 | All outbound |

### SSH Access Security Group (`sg-0079fee23ee54417a`)
**Name:** `allow-ssh_sg`

| Direction | Protocol | Port | Source/Dest | Description |
|-----------|----------|------|-------------|-------------|
| Inbound | TCP | 22 | 47.159.189.230/32 | SSH from restricted IP |
| Outbound | All | All | 0.0.0.0/0 | All outbound |

### ALB Public HTTPS Security Group (`sg-0a4bebabcd3bd4d20`) — ORPHANED
**Name:** `private-infra_alb-public-443`

| Direction | Protocol | Port | Source/Dest | Description |
|-----------|----------|------|-------------|-------------|
| Inbound | TCP | 443 | 0.0.0.0/0 | HTTPS from internet |
| Outbound | All | All | 0.0.0.0/0 | All outbound |

**Note:** Unattached — the ALB it fronted is gone (edge is the CF Tunnel). Still in
`networking/security_groups.tf` (`aws_security_group.alb_public`); a cleanup candidate.

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

## Public edge

**There is no ALB.** Public HTTPS for `*.wind.etherport.net` enters via the **Cloudflare
Tunnel** (`infra/terraform/cloudflare/main.tf`), not AWS. Infra-UI hostnames
(pdu/ups/prox/switch/traefik-dashboard) are **Tailscale-only**, resolved internally via
Technitium to the Traefik LB IP (`10.10.201.70`). The ALB → Traefik-over-WireGuard path is
retired — see [Migration history](#migration-history).

## Traffic Flow: Internet to Homelab

```
1. Client requests https://plex.wind.etherport.net
2. DNS resolves to a Cloudflare anycast IP (CF zone, proxied=true)
3. Cloudflare evaluates Access policy (Google SSO + email allowlist)
4. CF Tunnel forwards the request to a cloudflared pod in the cluster
5. cloudflared routes to the per-service backend per
   infra/terraform/cloudflare/main.tf ingress rules
6. Backend service responds (Plex, HA, etc.)
```

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

**Purpose:** Maintains 2 security groups (DNS :53 + SSH :22) so they only allow current homelab WAN1/WAN2 IPs. Resolves the target names via **public resolvers** (`1.1.1.1` then `8.8.8.8`) — zone-provider-agnostic, no API key; works against CF or whatever else serves those names.

**Flow:**
1. Triggered every 5 minutes (EventBridge)
2. Resolves `wind.etherport.net` / `wan1.wind.etherport.net` /
   `wan2.wind.etherport.net` via public DNS
3. Updates SG ingress rules for both target SGs to match the resolved
   IP set (defensive refusal to remove all rules if DNS returns empty)

### ddns-updater

| Property | Value |
|----------|-------|
| Function Name | `ddns-updater` |
| Runtime | Python 3.13 |
| Architecture | arm64 |
| Memory | 128 MB |
| Timeout | 10 seconds |
| Terraform Module | `infra/terraform/aws/ddns-lambda/` |

**Purpose:** DynDNS-compatible endpoint. UDM-Pro POSTs the current WAN1/WAN2 IP; Lambda upserts the matching record via the **Cloudflare REST API** (`https://api.cloudflare.com/client/v4`; CF token loaded from Secrets Manager alongside the router shared-secret).

### email-forward

| Property | Value |
|----------|-------|
| Function Name | `email-forward` |
| Runtime | Python 3.13 |
| Architecture | arm64 |
| Memory | 128 MB |
| Timeout | 30 seconds |
| Terraform Module | `infra/terraform/aws/email-forward/` |

**Purpose:** Generic per-prefix email forwarder. SES receipt rules deposit incoming emails to S3 under domain-specific prefixes; an S3 ObjectCreated event triggers this Lambda which forwards via SES SendRawEmail to the configured target. Domain-specific receipt rules live in whichever repo owns the domain (etherport.net here, the 3 personal domains in [sparked-diamond/personal-web](https://github.com/sparked-diamond/personal-web) — `terraform/ses-email-forward/`).

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

The read-only audit policy (`homelab-review` user) is defined as IaC — see the
JSON under `infra/terraform/aws/iam-policies/` (e.g. `terraform-iam-users.json`
and the per-service `terraform-*.json` documents). Don't hand-author it here.

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
- t4g.small for the edge box (resized from t4g.nano 2026-07-01, M110), t4g.nano for DNS (until consolidated)
- No NAT Gateway (using Internet Gateway + public IP for VPN)
- S3-native Terraform state locking (`use_lockfile=true` — no DynamoDB table)
- Lambda on ARM64 architecture

## Backup Strategy

- Configuration files in Git (this repo)
- WireGuard keys SOPS-encrypted in `platform/wireguard/servers/` (age)
- Technitium zones synced via GitOps from YAML files
- **EC2 instances are disposable** - no snapshots needed (Terraform + Ansible can recreate)
- **CloudWatch agent** on EC2 instances now publishes only 2 metrics
  (down from 15); host metrics moved to the Prometheus node_exporter
  scraped over the VPN. See commit 69ac7dd.

## External Monitoring

### Route53 Health Checks

External monitoring from AWS edge locations to detect homelab outages. Per-endpoint
`enabled` flags live in `external-monitoring/variables.tf`. The two disabled checks are a
re-enable follow-up (traefik has no public path — Tailscale-only).

| Endpoint | FQDN | Health Check Path | Status |
|----------|------|-------------------|--------|
| Home Assistant | ha.wind.etherport.net | / | Enabled |
| Plex | plex.wind.etherport.net | /identity | Enabled |
| Chat (Open WebUI) | chat.wind.etherport.net | / | Enabled |
| Grafana | grafana.wind.etherport.net | /api/health | Disabled |
| Traefik | traefik.wind.etherport.net | /ping | Disabled (Tailscale-only, no public path) |

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
├── main.tf                  # Health checks, alarms, SNS
├── variables.tf             # Endpoint configuration schema
├── terraform.tfvars.example # Endpoint definitions (template)
└── outputs.tf               # Health check IDs
```

## Terraform Infrastructure Modules

All AWS infrastructure is managed via Terraform under `infra/terraform/aws/`.

### Module Overview

| Module | State File | Resources Managed |
|--------|------------|-------------------|
| `networking/` | `aws/networking/terraform.tfstate` | VPC, subnets, route tables, IGW, security groups, NACLs |
| `compute/` | `aws/compute/terraform.tfstate` | EC2 instances, EIPs, IAM roles, CloudWatch alarms, SNS |
| `acm/` | `aws/acm/terraform.tfstate` | SSL/TLS certificates (us-west-2): `*.etherport.net`, `*.wind.etherport.net`, `ha.wind.etherport.net`. (Retained; no ALB consumer — HA uses in-cluster TLS.) |
| `s3/` | `aws/s3/terraform.tfstate` | S3 buckets (velero, archive, email-fwd, `postgres-barman.wind.etherport.net` for CNPG Barman WAL/base backups). All buckets carry bucket-policy `Deny` statements on `s3:DeleteBucket` and `s3:DeleteBucketPolicy` for non-root principals. |
| `ses/` | `aws/ses/terraform.tfstate` | SES domain/email identities + DKIM for **etherport.net only** (personal domains live in the [personal-web](https://github.com/sparked-diamond/personal-web) repo). |

> No `load-balancing/`, `route53/`, or `cloudflare-personal/` modules — those were removed in
> the CF migration ([Migration history](#migration-history)). Cloudflare is authoritative for
> etherport.net DNS; CF Tunnel is the edge.

### Lambda Modules

| Module | State File | Purpose |
|--------|------------|---------|
| `ddns-lambda/` | `aws/ddns-lambda/terraform.tfstate` | Dynamic DNS updater (API Gateway + Lambda) |
| `dns-restrict-ip/` | `aws/dns-restrict-ip/terraform.tfstate` | DNS security group IP updater |
| `email-forward/` | `aws/email-forward/terraform.tfstate` | SES email forwarding |
| `homeassistant-alexa/` | `aws/homeassistant-alexa/terraform.tfstate` | Home Assistant Alexa integration |
| `external-monitoring/` | `aws/external-monitoring/terraform.tfstate` | Route53 health checks and alerting |
| `twilio-webhook/` | `aws/twilio-webhook/terraform.tfstate` | Lambda (+API Gateway) handling Twilio status/webhook callbacks |

### Identity / IAM Modules

| Module | State File | Purpose |
|--------|------------|---------|
| `github-oidc/` | `aws/github-oidc/terraform.tfstate` | GitHub Actions → AWS OIDC federation; short-lived per-run CI creds (H29) |
| `cluster-irsa/` | `aws/cluster-irsa/terraform.tfstate` | In-cluster IRSA — OIDC provider + per-workload roles for velero/s3-sync/barman/cloudwatch-read; public OIDC issuer bucket (M75) |
| `roles-anywhere/` | `aws/roles-anywhere/terraform.tfstate` | IAM Roles Anywhere for the headless mini (step-ca leaf cert → STS, no standing key) (M71) |
| `ai-advisor-iam/` | `aws/ai-advisor-iam/terraform.tfstate` | Read-only CloudWatch Logs IAM user for the in-cluster AI advisor (M45) |

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

**Account identity:**
```
aws --profile homelab sts get-caller-identity
Account: 830881980142
```

## Resources Not in Terraform

The following resources exist but are managed manually or by other means:

- **Key Pairs:** `GS-EC2`, `Wordpress-key` - Created manually, private keys in 1Password

## Out of Scope (Public Web Infrastructure)

The stopthecastle.com / smithforsb.com / grahamsmith.net resources
(CloudFront, S3, ACM us-east-1, EC2 WordPress, CF DNS, SES domain
identities, email-forward receipt rules) live in
[sparked-diamond/personal-web](https://github.com/sparked-diamond/personal-web).
The email-forward Lambda code itself stays in this repo as a generic
per-prefix forwarder; personal-web's receipt rules reference it via
`data "aws_lambda_function"`. See the personal-web README for the
homelab/personal-web boundary.

## Migration history

How this footprint reached its current shape — the 2026-05-27 **ALB → Cloudflare Tunnel +
CF Access** cutover, the **Route53 → Cloudflare DNS** move (and the resulting
ddns-updater/dns-restrict-ip rewrites), and the deleted `load-balancing/`/`route53/`/
`cloudflare-personal/` modules — is archived in
[`archive/aws-infrastructure-migration-history.md`](archive/aws-infrastructure-migration-history.md).
See also the runbooks [`alb-decom.md`](../runbooks/archive/alb-decom.md),
[`cloudflare-access-enable.md`](../runbooks/archive/cloudflare-access-enable.md), and
[`ddns-updater-cf-migration.md`](../runbooks/archive/ddns-updater-cf-migration.md).
