# GitHub Actions Automation

This repository uses GitHub Actions for CI/CD automation of container images and infrastructure deployment.

## Overview

Key workflows (not exhaustive — there are ~45 in `.github/workflows/`; run `ls .github/workflows/` for the full set):

```
.github/workflows/
├── aws-s3-sync-image.yml       # Container image build for S3 backup
└── cloudflare-ddns-image.yml   # Container image build for DDNS updater
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
- Package visibility is set to Public **manually** (one-time, via PAT/UI — `GITHUB_TOKEN`
  can't flip GHCR visibility); the build then **verifies the image is publicly pullable
  and fails if it regressed** to private

### 2. Terraform Infrastructure

Deploy infrastructure via Terraform with plan/apply/destroy capabilities.

**Authentication (current):**
- **AWS stacks** run on GitHub-hosted runners with **GitHub→AWS OIDC** (H29) —
  short-lived per-run credentials, **no static AWS keys in CI**.
- **PVE/UniFi/Cloudflare/Google/Twilio stacks** run on the self-hosted `lifecycle`
  runner with creds as GH secrets. (UniFi uses the `ubiquiti-community/unifi`
  provider with `UNIFI_API_KEY`, M125.)
- GCP uses **Workload Identity Federation** (L21).
- The devbox has no `gh` CLI — it dispatches workflows via the GitHub REST API with
  the Actions:write PAT (M92).

**Triggers:**
- Push to `main`: Validation plan only
- Pull request: Validation plan only
- Manual dispatch: Full plan/apply/destroy with parameters

## Regional VPN Terraform Workflow (DELETED 2026-07-01)

> The travel-VPN tooling — `terraform-regional-vpn.yml`, `infra/terraform/aws-regional-vpn/`,
> `infra/terraform/modules/regional-vpn/`, and `platform/wireguard/regional-peers.yaml` — was
> **deleted 2026-07-01** (M110): no travel VPN had been deployed since 2026-05-23, both TF
> workspaces held 0 resources, and Tailscale covers travel access. The full historical
> deployment procedure is preserved in the
> [archived Regional VPN Deployment Runbook](../../runbooks/archive/regional-vpn-deployment.md);
> resurrecting the capability means restoring those paths from git history (this commit's parent).

## Container Image Workflows

### aws-s3-sync-image.yml

Builds the `aws-s3-sync` container for Kubernetes backup jobs.

**Path:** `platform/kubernetes/backups/aws-s3/image/`

**Image:** `ghcr.io/sparked-diamond/aws-s3-sync:main`

**Purpose:** Sync Kubernetes backups to S3 buckets

### cloudflare-ddns-image.yml

Builds the `cloudflare-ddns` container for dynamic DNS updates.

**Path:** `platform/kubernetes/cloudflare-ddns/image/`

**Image:** `ghcr.io/sparked-diamond/cloudflare-ddns:main`

**Purpose:** Update Cloudflare DNS records when the homelab IP changes (Route53 retired 2026-05-27; DNS is authoritative on Cloudflare)

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

For new Terraform workflows (NB: new AWS workflows should authenticate via the
**OIDC role** like the existing `terraform-*.yml` AWS workflows do — copy one of
those; the profile plumbing below exists so the same stacks also run locally with
the rendered `[homelab]` profile):

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
gh run list --workflow="terraform-compute.yml" --limit 5

# View specific run
gh run view <run-id>

# View failed step logs
gh run view <run-id> --log-failed

# Watch running workflow
gh run watch <run-id>
```

## See Also

- [Regional VPN Deployment Runbook (archived)](../../runbooks/archive/regional-vpn-deployment.md)
- [SOPS Setup Guide](../secrets/SOPS-SETUP.md)
- [AWS Infrastructure Architecture](../../architecture/aws-infrastructure.md)
