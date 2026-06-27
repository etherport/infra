# GitHub Actions Infrastructure Automation Roadmap

Analysis of homelab-infra Terraform modules and recommendations for GitHub Actions automation.

## Current State

| Workflow | Purpose | Status |
|----------|---------|--------|
| `aws-s3-sync-image.yml` | Build S3 backup container | Active |
| `route53-ddns-image.yml` | Build DDNS container | Active |
| `terraform-regional-vpn.yml` | Deploy travel VPN | Active |

## Terraform Modules Analysis

### AWS Modules

| Module | Change Frequency | Secrets | Automation Fit |
|--------|------------------|---------|----------------|
| `acm/` | Very Low | No | Low - static certificates |
| `compute/` | Medium | No | Medium - has prevent_destroy |
| `ddns-lambda/` | Low | Yes (API key) | Medium |
| `dns-restrict-ip/` | Low | No | Medium |
| `email-forward/` | Medium-High | No | **High** |
| `external-monitoring/` | Medium | No | **High** |
| `homeassistant-alexa/` | Low | Yes (HA token) | Low |
| `load-balancing/` | Low | No | Medium - has prevent_destroy |
| `networking/` | Very Low | No | Low - core infrastructure |
| `route53/` | High | No | **High** |
| `s3/` | Low | No | Low |
| `ses/` | Low-Medium | No | Medium |

### Proxmox Modules

| Module | Change Frequency | Secrets | Automation Fit |
|--------|------------------|---------|----------------|
| `k8s-vms/` | Medium | Yes (API token) | Medium - needs approval |
| `standalone-vms/` | Medium-High | Yes (API token) | **High** |

## Recommended Automation Priority

### Phase 1: High Value, Low Risk (Immediate)

#### 1. Route53 DNS Management

**Why:** DNS records change frequently. Automating plan-on-PR and apply-on-merge provides validation and audit trail.

**Workflow Features:**
- Plan on pull request with comment showing changes
- Apply on merge to main
- Manual dispatch for ad-hoc changes
- No secrets required (IAM via env vars)

**Implementation Effort:** Low (similar pattern to regional-vpn)

```yaml
# .github/workflows/terraform-route53.yml
on:
  push:
    branches: [main]
    paths: ['infra/terraform/aws/route53/**']
  pull_request:
    paths: ['infra/terraform/aws/route53/**']
  workflow_dispatch:
    inputs:
      action:
        type: choice
        options: [plan, apply]
```

#### 2. External Monitoring

**Why:** Monitoring endpoints are updated as services change. Automated deployment ensures alerting stays current.

**Workflow Features:**
- Plan on PR
- Apply on merge
- Validates health check configuration

**Implementation Effort:** Low

### Phase 2: Medium Value, Medium Risk

#### 3. Email Forward Lambda

**Why:** Email recipient changes are common. Automation reduces manual deployment steps.

**Workflow Features:**
- Plan on PR (shows SES/Lambda changes)
- Apply on merge
- Requires SOPS for secret decryption (if any added)

**Implementation Effort:** Medium

#### 4. Proxmox Standalone VMs

**Why:** Service VMs (dns-fallback, vpn-local) are added/modified frequently. Automation provides consistency.

**Workflow Features:**
- Plan on PR with approval gate
- Manual apply only (critical infrastructure)
- Requires Proxmox API token secret

**Considerations:**
- Proxmox API must be reachable from GitHub runners (may need self-hosted runner or VPN)
- Consider using [GitHub-hosted larger runners](https://docs.github.com/en/actions/using-github-hosted-runners) or self-hosted

**Implementation Effort:** High (network access challenge)

### Phase 3: Lower Value or Higher Risk

#### 5. Load Balancing (with Approval Gate)

**Why:** ALB changes are infrequent but impactful. Automation with approval provides safety.

**Workflow Features:**
- Plan on PR
- Manual apply with environment protection
- prevent_destroy requires careful handling

**Implementation Effort:** Medium

#### 6. Compute (EC2 Instances)

**Why:** Instance changes are rare but documentation of changes is valuable.

**Workflow Features:**
- Plan only on PR (for visibility)
- Manual apply via workflow_dispatch
- environment protection rules

**Implementation Effort:** Medium

### Not Recommended for Automation

| Module | Reason |
|--------|--------|
| `networking/` | Core infrastructure, too risky for automated changes |
| `acm/` | Very infrequent changes, manual is fine |
| `s3/` | Low change frequency, manual oversight preferred |
| `homeassistant-alexa/` | Rarely changes, complex secrets |
| `k8s-vms/` | Critical infrastructure, manual control preferred |

## Implementation Patterns

### Standard Pattern (No Secrets)

```yaml
jobs:
  terraform:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: hashicorp/setup-terraform@v4
      - uses: aws-actions/configure-aws-credentials@v5
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: us-west-2
      - run: terraform init -backend-config="profile="
      - run: terraform plan -var="aws_profile=" -no-color
```

### SOPS Pattern (With Secrets)

```yaml
jobs:
  terraform:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: hashicorp/setup-terraform@v4
      - uses: aws-actions/configure-aws-credentials@v5
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: us-west-2
      - name: Install SOPS
        run: |
          curl -LO https://github.com/getsops/sops/releases/download/v3.9.4/sops-v3.9.4.linux.amd64
          sudo mv sops-v3.9.4.linux.amd64 /usr/local/bin/sops
          sudo chmod +x /usr/local/bin/sops
      - name: Configure SOPS
        run: |
          mkdir -p ~/.config/sops/age
          echo "${{ secrets.SOPS_AGE_KEY }}" > ~/.config/sops/age/keys.txt
          chmod 600 ~/.config/sops/age/keys.txt
      - run: terraform init -backend-config="profile="
      - run: terraform plan -var="aws_profile=" -no-color
```

### Approval Gate Pattern (Critical Infrastructure)

```yaml
jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - run: terraform plan -out=tfplan
      - uses: actions/upload-artifact@v4
        with:
          name: tfplan
          path: tfplan

  apply:
    needs: plan
    runs-on: ubuntu-latest
    environment: production  # Requires approval
    steps:
      - uses: actions/download-artifact@v4
      - run: terraform apply tfplan
```

## Required Secrets

| Secret | Required For | Notes |
|--------|--------------|-------|
| `AWS_ACCESS_KEY_ID` | All AWS modules | terraform-homelab user |
| `AWS_SECRET_ACCESS_KEY` | All AWS modules | |
| `SOPS_AGE_KEY` | Modules with encrypted secrets | Age private key |
| `PROXMOX_TOKEN_ID` | Proxmox modules | Future, if network accessible |
| `PROXMOX_TOKEN_SECRET` | Proxmox modules | Future, if network accessible |

## Proxmox Automation Challenges

Proxmox modules present unique challenges for GitHub Actions:

1. **Network Access**: Proxmox API is on local network, not internet-accessible
2. **VPN Requirement**: Would need VPN tunnel from runner to homelab
3. **Self-Hosted Runner**: Could run runner inside homelab network

### Options

| Approach | Pros | Cons |
|----------|------|------|
| Self-hosted runner in K8s | Direct network access | Maintenance overhead |
| Tailscale on GitHub runner | Easy setup | Requires Tailscale auth |
| WireGuard tunnel in workflow | Full control | Complex setup |
| Skip automation | Simple | No CI/CD benefits |

**Recommendation:** Start with AWS-only automation. Consider self-hosted runner in K8s for Proxmox if demand increases.

## Implementation Order

1. **Route53** - High frequency, low risk, immediate value
2. **External Monitoring** - Related to Route53, quick win
3. **Email Forward** - Medium frequency, low risk
4. *(Evaluate Phase 2 needs before continuing)*
5. **Load Balancing** - With approval gates
6. **Compute** - Plan-only initially

## Migration Steps for Each Module

### Pre-Migration Checklist

- [ ] Add `aws_profile` variable to provider configuration
- [ ] Update provider blocks to use conditional profile
- [ ] Test locally with `aws_profile=""` to verify env var auth works
- [ ] Document any module-specific considerations

### Workflow Creation

1. Copy pattern from `terraform-regional-vpn.yml`
2. Update paths, variables, and working directory
3. Add appropriate triggers (push, PR, dispatch)
4. Test with plan-only on PR
5. Enable apply on merge after validation

## Metrics to Track

- Workflow run duration
- Success/failure rate
- Time from PR to apply
- Number of manual interventions required

## See Also

- [GitHub Actions Documentation](../../setup/github-actions/README.md)
- [AWS Infrastructure Architecture](../../architecture/aws-infrastructure.md)
- [Remote State Backend](../../setup/terraform/remote-state-backend.md)
