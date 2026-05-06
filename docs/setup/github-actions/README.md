# GitHub Actions Automation

This repository uses GitHub Actions for CI/CD automation of container images and infrastructure deployment.

## Overview

```
.github/workflows/
├── aws-s3-sync-image.yml       # Container image build for S3 backup
├── route53-ddns-image.yml      # Container image build for DDNS updater
└── terraform-regional-vpn.yml  # Terraform deployment for travel VPN
```

## Workflow Types

### 1. Container Image Builds

Automatically build and push container images to GitHub Container Registry (GHCR) when Dockerfiles change.

**Triggers:**
- Push to `main` branch (build + push)
- Pull request to `main` (build only, no push)
- Manual dispatch via GitHub UI

**Features:**
- Multi-arch builds via Docker Buildx
- Tags: `main` and `sha-<commit>`
- Automatic package visibility set to public

### 2. Terraform Infrastructure

Deploy AWS infrastructure via Terraform with plan/apply/destroy capabilities.

**Triggers:**
- Push to `main`: Validation plan only
- Pull request: Validation plan only
- Manual dispatch: Full plan/apply/destroy with parameters

## Regional VPN Terraform Workflow

The `terraform-regional-vpn.yml` workflow automates temporary travel VPN deployment to any AWS region.

### How It Works

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        GitHub Actions Workflow                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  1. TRIGGER                                                                  │
│     ├── Push/PR: Validate terraform (plan only)                            │
│     └── Manual Dispatch: Choose action (plan/apply/destroy)                │
│                                                                              │
│  2. ENVIRONMENT SETUP                                                        │
│     ├── Checkout repository                                                  │
│     ├── Install Terraform 1.14.3                                            │
│     ├── Configure AWS credentials (via secrets)                             │
│     ├── Install SOPS binary                                                  │
│     └── Configure SOPS age key (for secret decryption)                      │
│                                                                              │
│  3. TERRAFORM INIT                                                           │
│     └── Initialize with S3 backend (profile override for CI)               │
│                                                                              │
│  4. WORKSPACE SELECTION (manual dispatch only)                              │
│     └── Select or create terraform workspace for the region                 │
│                                                                              │
│  5. ACTION EXECUTION                                                         │
│     ├── Plan: Show what would change                                        │
│     ├── Apply: Create/update infrastructure                                 │
│     │   ├── Generate WireGuard keys (if new deployment)                    │
│     │   ├── Deploy VPC, EC2, VPN config                                     │
│     │   ├── Update vpn-travel.etherport.net DNS                            │
│     │   ├── Update regional-peers.yaml config                               │
│     │   └── Commit and push config changes                                  │
│     └── Destroy: Tear down infrastructure                                   │
│         ├── Destroy all AWS resources                                        │
│         ├── Clear regional-peers.yaml                                        │
│         └── Commit and push config changes                                  │
│                                                                              │
│  6. SUMMARY                                                                  │
│     └── Write job summary with region, IP, DNS info                        │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Secrets Required

| Secret | Description |
|--------|-------------|
| `AWS_ACCESS_KEY_ID` | AWS credentials for terraform-homelab user |
| `AWS_SECRET_ACCESS_KEY` | AWS secret key |
| `SOPS_AGE_KEY` | Age private key for decrypting SOPS secrets |

### Manual Dispatch Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `action` | Operation to perform | `plan`, `apply`, `destroy` |
| `workspace` | Terraform workspace name | `mumbai`, `bahrain` |
| `region` | AWS region code | `ap-south-1`, `me-south-1` |
| `region_short` | Short name for resources | `mumbai`, `bahrain` |
| `vpc_cidr` | VPC CIDR block | `10.10.112.0/24` |
| `tunnel_ip` | WireGuard tunnel IP | `10.255.255.3` |

### Automatic Actions After Apply

1. **DNS Update**: Updates `vpn-travel.etherport.net` A record to new VPN IP
2. **Config Update**: Writes `platform/wireguard/regional-peers.yaml` with:
   - Region name and status
   - Public IP and WireGuard keys
   - VPC CIDR and allowed IPs
3. **Git Commit**: Commits and pushes config changes back to repo

### Local vs CI Differences

| Aspect | Local | CI (GitHub Actions) |
|--------|-------|---------------------|
| AWS Auth | `~/.aws/credentials` profile | Environment variables |
| SOPS Key | `~/.config/sops/age/keys.txt` | `SOPS_AGE_KEY` secret |
| Backend Profile | `homelab` | Overridden to empty |
| Provider Profile | `homelab` | `-var="aws_profile="` |

### Usage Examples

**Deploy Mumbai VPN:**
1. Go to Actions > Regional VPN Terraform > Run workflow
2. Select:
   - Action: `apply`
   - Workspace: `mumbai`
   - Region: `ap-south-1`
   - Region short: `mumbai`
   - VPC CIDR: `10.10.112.0/24`
   - Tunnel IP: `10.255.255.3`

**Destroy when done traveling:**
1. Same workflow, Action: `destroy`
2. Use same parameters as apply

## Container Image Workflows

### aws-s3-sync-image.yml

Builds the `aws-s3-sync` container for Kubernetes backup jobs.

**Path:** `platform/kubernetes/backups/aws-s3/image/`

**Image:** `ghcr.io/sparked-diamond/aws-s3-sync:main`

**Purpose:** Sync Kubernetes backups to S3 buckets

### route53-ddns-image.yml

Builds the `route53-ddns` container for dynamic DNS updates.

**Path:** `platform/kubernetes/route53-ddns/image/`

**Image:** `ghcr.io/sparked-diamond/route53-ddns:main`

**Purpose:** Update Route53 DNS records when homelab IP changes

## Adding New Workflows

### Container Image Template

```yaml
name: Build <name> image

on:
  push:
    branches: [main]
    paths:
      - 'path/to/image/**'
      - '.github/workflows/<name>-image.yml'
  pull_request:
    branches: [main]
    paths:
      - 'path/to/image/**'
  workflow_dispatch: {}

permissions:
  contents: read
  packages: write

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: docker/setup-buildx-action@v4
      - uses: docker/login-action@v4
        if: github.event_name != 'pull_request'
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/build-push-action@v7
        with:
          context: path/to/image
          push: ${{ github.event_name != 'pull_request' }}
          tags: |
            ghcr.io/sparked-diamond/<name>:main
            ghcr.io/sparked-diamond/<name>:sha-${{ github.sha }}
```

### Terraform Workflow Considerations

For new Terraform workflows:

1. **Backend Profile Override**: Always add `-backend-config="profile="` to `terraform init`
2. **Provider Profile Variable**: Add `aws_profile` variable with conditional:
   ```hcl
   variable "aws_profile" {
     default = "homelab"
   }

   provider "aws" {
     profile = var.aws_profile != "" ? var.aws_profile : null
   }
   ```
3. **Pass Empty Profile in CI**: Add `-var="aws_profile="` to all terraform commands
4. **SOPS Setup**: Install SOPS binary and configure age key if secrets are needed

## Security

- **Secrets**: Stored in GitHub repository settings, never in code
- **AWS Permissions**: Terraform user has scoped permissions for specific resources
- **SOPS**: Secrets are encrypted at rest, decrypted only during workflow execution
- **No Sensitive Outputs**: Workflow logs do not expose keys or credentials

## Troubleshooting

### Common Issues

**"failed to get shared config profile, homelab"**
- Cause: AWS provider trying to use local profile in CI
- Fix: Ensure `-var="aws_profile="` is passed to terraform commands

**"Unable to resolve action"**
- Cause: Action version doesn't exist
- Fix: Check for latest stable version of the action

**Workspace selection fails on push**
- Cause: Condition running when no inputs provided
- Fix: Add `github.event_name == 'workflow_dispatch'` to condition

### Checking Workflow Logs

```bash
# List recent runs
gh run list --workflow="terraform-regional-vpn.yml" --limit 5

# View specific run
gh run view <run-id>

# View failed step logs
gh run view <run-id> --log-failed

# Watch running workflow
gh run watch <run-id>
```

## See Also

- [Regional VPN Deployment Runbook](../../runbooks/regional-vpn-deployment.md)
- [SOPS Setup Guide](../secrets/SOPS-SETUP.md)
- [AWS Infrastructure Architecture](../../architecture/aws-infrastructure.md)
