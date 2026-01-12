# Container Image Versioning & Release Strategy

## Current State

**What we have now:**
- ✅ Images auto-build on push to `main`
- ✅ Two tags per build: `:main` and `:sha-{commit}`
- ✅ Auto-public after build
- ❌ No semantic versioning
- ❌ No release management
- ❌ Can't easily rollback

**Issues:**
- `:main` tag is mutable (changes without notice)
- Hard to track what version is deployed
- No way to pin to stable releases
- Rollback requires finding git SHA

## Recommended Strategy: Semantic Versioning + Git Tags

### Version Format

Use [Semantic Versioning](https://semver.org/):
- **v1.0.0** - Major.Minor.Patch
- **v1.1.0** - New features (backwards compatible)
- **v1.0.1** - Bug fixes
- **v2.0.0** - Breaking changes

### Tag Strategy

| Tag | Purpose | Mutability | Use Case |
|-----|---------|------------|----------|
| `:v1.2.3` | Specific release | Immutable | Production (pinned version) |
| `:v1.2` | Latest patch | Mutable | Auto-patch updates |
| `:v1` | Latest minor | Mutable | Auto-minor updates |
| `:latest` | Latest stable release | Mutable | Quick testing |
| `:main` | Latest dev build | Mutable | Development/testing |
| `:sha-abc123` | Specific commit | Immutable | Debugging/rollback |

### Workflow Updates

Update `.github/workflows/route53-ddns-image.yml`:

```yaml
name: Build route53-ddns image

on:
  push:
    branches: [ "main" ]
    tags:
      - 'v*.*.*'  # Trigger on version tags
    paths:
      - "platform/kubernetes/route53-ddns/image/**"
      - ".github/workflows/route53-ddns-image.yml"
  pull_request:
    branches: [ "main" ]
  workflow_dispatch: {}

permissions:
  contents: read
  packages: write

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Docker meta
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ghcr.io/sparked-diamond/route53-ddns
          tags: |
            # For git tags (v1.2.3)
            type=semver,pattern={{version}}
            type=semver,pattern={{major}}.{{minor}}
            type=semver,pattern={{major}}

            # For main branch commits
            type=raw,value=main,enable={{is_default_branch}}
            type=sha,prefix=sha-

            # Mark latest stable on version tags
            type=raw,value=latest,enable=${{ startsWith(github.ref, 'refs/tags/v') }}

      - name: Set up Buildx
        uses: docker/setup-buildx-action@v3

      - name: Login to GHCR
        if: github.event_name != 'pull_request'
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: platform/kubernetes/route53-ddns/image
          push: ${{ github.event_name != 'pull_request' }}
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}

      - name: Make package public
        if: github.event_name != 'pull_request'
        run: |
          curl -X PATCH \
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer ${{ secrets.GITHUB_TOKEN }}" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            https://api.github.com/orgs/sparked-diamond/packages/container/route53-ddns \
            -d '{"visibility":"public"}'
```

### Release Process

#### 1. Create a Release

```bash
# Ensure main branch is in good state
git checkout main
git pull

# Create and push version tag
git tag -a v1.0.0 -m "Release v1.0.0

Features:
- Initial production release
- Multi-domain Route53 DDNS support
- Prometheus metrics integration
- Email alerting on failures
"

git push origin v1.0.0
```

This triggers GitHub Actions to build and push:
- `ghcr.io/sparked-diamond/route53-ddns:v1.0.0`
- `ghcr.io/sparked-diamond/route53-ddns:v1.0`
- `ghcr.io/sparked-diamond/route53-ddns:v1`
- `ghcr.io/sparked-diamond/route53-ddns:latest`

#### 2. Update Kubernetes to Use Version

```yaml
# platform/kubernetes/route53-ddns/base/cronjob.yaml
spec:
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: ddns
              # Use specific version for production
              image: ghcr.io/sparked-diamond/route53-ddns:v1.0.0
              # Or auto-update patches: v1.0
              # Or auto-update minor: v1
              imagePullPolicy: IfNotPresent  # Changed from Always
```

#### 3. Deploy Update

```bash
cd platform/kubernetes/route53-ddns/base
kubectl apply -k .

# Verify new version
kubectl get cronjob route53-ddns -n route53-ddns -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].image}'
```

### Rollback Process

If a release has issues:

```bash
# Option 1: Rollback to previous version tag
kubectl set image cronjob/route53-ddns \
  -n route53-ddns \
  ddns=ghcr.io/sparked-diamond/route53-ddns:v1.0.0

# Option 2: Rollback using git SHA (for testing)
kubectl set image cronjob/route53-ddns \
  -n route53-ddns \
  ddns=ghcr.io/sparked-diamond/route53-ddns:sha-abc123def

# Option 3: Update git and redeploy
cd platform/kubernetes/route53-ddns/base
# Edit cronjob.yaml to previous version
kubectl apply -k .
```

### Version Bump Guidelines

**Patch (v1.0.x)** - Bug fixes, no new features
```bash
git tag -a v1.0.1 -m "Fix: Route53 API retry logic"
```

**Minor (v1.x.0)** - New features, backwards compatible
```bash
git tag -a v1.1.0 -m "Feature: Add CloudFlare DNS support"
```

**Major (vX.0.0)** - Breaking changes
```bash
git tag -a v2.0.0 -m "Breaking: Migrate to new config format"
```

### Development Workflow

```
main branch (:main tag)
    ↓
  Testing
    ↓
  Create git tag → v1.2.3
    ↓
  GitHub Actions builds
    ↓
  Tags: v1.2.3, v1.2, v1, latest
    ↓
  Update Kubernetes manifests
    ↓
  kubectl apply -k .
    ↓
  Production
```

### Alternative: Date-based Versioning

If semantic versioning feels too heavyweight:

```yaml
# Generate version from timestamp
tags: |
  type=raw,value={{date 'YYYYMMDD.HHmmss'}}
  type=raw,value=main

# Results in: 20260102.143022
```

**Pros:**
- Simple, automatic
- Chronological ordering
- No need to decide version numbers

**Cons:**
- Doesn't convey compatibility
- No major/minor/patch distinction

## Automated Changelog Generation

Use [conventional commits](https://www.conventionalcommits.org/) to auto-generate changelogs:

```bash
# Commit format
feat: add CloudFlare DNS support
fix: retry Route53 API calls on 429
docs: update configuration examples
chore: update dependencies

# Generate changelog from commits
git log v1.0.0..HEAD --pretty=format:"- %s" --grep="^feat\|^fix"
```

## Monitoring Deployed Versions

Add version label to pods:

```yaml
# cronjob.yaml
metadata:
  labels:
    app: route53-ddns
    version: v1.0.0  # Update with each release
```

Query deployed versions:
```bash
kubectl get pods -A -l app=route53-ddns -o jsonpath='{range .items[*]}{.metadata.labels.version}{"\n"}{end}' | sort -u
```

## Best Practices

1. **Tag in git first** - Create release tag before deploying
2. **Test before tagging** - Run tests on `:main` before creating release tag
3. **Use immutable tags in production** - Pin to `v1.2.3`, not `:latest`
4. **Document releases** - Include changelog in git tag message
5. **Keep old versions** - Don't delete old image tags (storage is cheap)
6. **Automate where possible** - Use GitHub Actions for builds
7. **Version everything** - Both images should use same strategy

## Migration Plan

### Phase 1: Add Versioning (Now)
- Update workflows with metadata-action
- Keep current `:main` behavior
- Add support for version tags

### Phase 2: Create First Release (Next Deploy)
- Tag current state as `v1.0.0`
- Build and test versioned image
- Update one deployment to use version

### Phase 3: Standardize (Over Time)
- Move all deployments to versioned images
- Document release process in runbooks
- Train team on version workflow

## References

- [Semantic Versioning](https://semver.org/)
- [Docker Metadata Action](https://github.com/docker/metadata-action)
- [Conventional Commits](https://www.conventionalcommits.org/)
- [Keep a Changelog](https://keepachangelog.com/)
