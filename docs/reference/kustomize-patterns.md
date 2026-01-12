# Kustomize Patterns

Common Kustomize patterns used in this repository for Flux GitOps management.

## Overview

This repository uses Kustomize to manage Kubernetes manifests. Kustomize allows us to define base configurations and overlay them with environment-specific customizations without duplicating YAML.

## Pattern 1: Simple Application (Single Directory)

**Used by**: Plex, iCloudPD, Kopia

**Structure**:
```
platform/kubernetes/plex/
├── kustomization.yaml
├── 00-namespace.yaml
├── 01-pvc-config.yaml
├── 02-deployment.yaml
├── 03-service.yaml
└── 04-ingress.yaml
```

**kustomization.yaml**:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: plex

resources:
  - 00-namespace.yaml
  - 01-pvc-config.yaml
  - 02-deployment.yaml
  - 03-service.yaml
  - 04-ingress.yaml
```

**When to use**: Simple applications that don't need per-environment customization.

## Pattern 2: ConfigMap Generator (Automatic Pod Restart)

**Used by**: Home Automation

**Structure**:
```
platform/kubernetes/home-automation/
├── kustomization.yaml
├── configuration.yaml       # Config file
├── deployment.yaml
└── ...
```

**kustomization.yaml**:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: home-automation

resources:
  - namespace.yaml
  - deployment.yaml
  - service.yaml
  - ingressroute.yaml
  - pvc.yaml

configMapGenerator:
  - name: home-assistant-config
    files:
      - configuration.yaml
```

**How it works**:
1. Kustomize generates ConfigMap from `configuration.yaml`
2. ConfigMap name gets hash suffix: `home-assistant-config-abc123xyz`
3. Deployment references ConfigMap by name
4. When config changes, new hash is generated
5. Kubernetes sees new ConfigMap name → triggers rolling restart
6. **Pod automatically restarts with new configuration**

**Benefits**:
- Automatic pod restart on configuration changes
- No manual `kubectl rollout restart` needed
- GitOps-friendly: commit config → automatic deployment

**When to use**: Applications with configuration files that need automatic pod restarts when changed.

## Pattern 3: Base + Overlays (Environment-Specific)

**Used by**: AWS S3 Backups

**Structure**:
```
platform/kubernetes/backups/aws-s3/
├── base/
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── serviceaccount.yaml
│   ├── rbac.yaml
│   ├── cronjob.yaml
│   └── excludes-global.txt
└── shares/
    ├── scans/
    │   ├── kustomization.yaml
    │   ├── patch.yaml
    │   └── excludes-share.txt
    ├── graham/
    │   ├── kustomization.yaml
    │   ├── patch.yaml
    │   └── excludes-share.txt
    └── ...
```

**base/kustomization.yaml**:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: backups

resources:
  - namespace.yaml
  - serviceaccount.yaml
  - rbac.yaml
  - cronjob.yaml

configMapGenerator:
  - name: aws-s3-sync-excludes-global
    files:
      - excludes-global.txt

generatorOptions:
  disableNameSuffixHash: true
```

**shares/scans/kustomization.yaml**:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: backups

resources:
  - ../../base

namePrefix: s3-sync-scans-

patches:
  - target:
      group: batch
      version: v1
      kind: CronJob
      name: s3-sync-template
      namespace: backups
    path: patch.yaml

configMapGenerator:
  - name: aws-s3-sync-excludes-share
    files:
      - excludes-share.txt

generatorOptions:
  disableNameSuffixHash: true
```

**shares/scans/patch.yaml**:
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: s3-sync-template
spec:
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: s3-sync
            env:
            - name: SHARE_NAME
              value: "scans"
            - name: DEST_PREFIX
              value: "objects/scans"
            volumeMounts:
            - name: nfs-src
              mountPath: /mnt/src
              readOnly: true
          volumes:
          - name: nfs-src
            nfs:
              server: sequoia.wind.etherport.net
              path: /var/nfs/shared/Scans
```

**How it works**:
1. Base defines common resources (CronJob template, RBAC, etc.)
2. Each share overlay references base: `resources: - ../../base`
3. Overlay patches the CronJob with share-specific values
4. `namePrefix` makes each share unique: `s3-sync-scans-s3-sync-template`
5. Share-specific ConfigMaps provide per-share excludes

**Benefits**:
- DRY (Don't Repeat Yourself): Common config in one place
- Easy to add new shares: copy overlay directory, update patch
- Consistent structure across all shares

**When to use**: Multiple similar deployments that differ only in specific values.

## Pattern 4: Excluding Resources from Kustomization

**Used by**: Kopia, iCloudPD (for secrets not in git)

**kustomization.yaml**:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: backups

resources:
  - 01-pvc-repo.yaml
  - 02-pvc-config.yaml
  # Note: 03-secret-template.yaml should be applied manually
  # - 03-secret-template.yaml
  - 04-configmap-entrypoint.yaml
  - 05-deployment.yaml
```

**Why**: Secrets shouldn't be in git (excluded by `.gitignore`). They must be created manually or via SOPS encryption.

**When to use**: When you have secrets that can't be committed to git.

## Pattern 5: Shared Namespace (Multiple Apps, One Namespace)

**Used by**: Kopia + AWS S3 Backups (both in `backups` namespace)

**Problem**: Both apps define `00-namespace.yaml` → duplicate resource error in Flux.

**Solution**: Only one app defines the namespace, others comment it out:

**aws-s3/base/kustomization.yaml** (defines namespace):
```yaml
resources:
  - namespace.yaml  # Defines backups namespace
  - serviceaccount.yaml
  - rbac.yaml
```

**kopia/kustomization.yaml** (references namespace but doesn't define it):
```yaml
namespace: backups  # Uses backups namespace

resources:
  # Note: namespace already defined by aws-s3/base
  # - 00-namespace.yaml
  - 01-pvc-repo.yaml
  - 02-pvc-config.yaml
```

**When to use**: Multiple apps sharing the same namespace in Flux.

## Pattern 6: Infrastructure Resources (Minimal)

**Used by**: MetalLB, Traefik

**Structure**:
```
platform/kubernetes/metallb/
├── kustomization.yaml
└── metallb-wind.yaml
```

**kustomization.yaml**:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - metallb-wind.yaml
```

**When to use**: Simple configuration resources that don't need a namespace or complex structure.

## Pattern 7: Disabling Hash Suffix

**Used by**: AWS S3 Backups (for stable ConfigMap names)

**kustomization.yaml**:
```yaml
configMapGenerator:
  - name: aws-s3-sync-excludes-global
    files:
      - excludes-global.txt

generatorOptions:
  disableNameSuffixHash: true
```

**Why**: By default, ConfigMap generators add hash suffixes. Disabling gives stable names but **prevents automatic pod restarts** on ConfigMap changes.

**When to use**:
- When you want stable ConfigMap names
- When you don't need automatic pod restarts
- When you'll manually restart pods after config changes

## Common Kustomize Operations

### Build and Preview

```bash
# Build kustomization (dry-run)
kubectl kustomize path/to/app/

# Pipe to less for easier reading
kubectl kustomize path/to/app/ | less

# Count resources
kubectl kustomize path/to/app/ | grep "^kind:" | sort | uniq -c
```

### Test Locally Before Committing

```bash
# Build and validate
kubectl kustomize path/to/app/ > /tmp/test.yaml
kubectl apply --dry-run=client -f /tmp/test.yaml

# Or in one command
kubectl kustomize path/to/app/ | kubectl apply --dry-run=client -f -
```

### Apply Manually (Bypass Flux)

```bash
# Apply kustomization directly
kubectl apply -k path/to/app/

# Delete kustomization
kubectl delete -k path/to/app/
```

## Best Practices

### Do's ✅

1. **Use ConfigMap generators** for config files that need automatic pod restarts
2. **Number files** (00-, 01-, 02-) for clear ordering
3. **Keep namespaces consistent** across base and overlays
4. **Use base + overlays** for multiple similar deployments
5. **Comment excluded resources** to document why they're not included
6. **Test locally** with `kubectl kustomize` before committing

### Don'ts ❌

1. **Don't commit secrets** to git (use SOPS or manual creation)
2. **Don't define the same resource twice** (e.g., same namespace in multiple apps)
3. **Don't use complex patches** when a simple overlay would work
4. **Don't disable hash suffix** unless you have a good reason
5. **Don't skip testing** - broken kustomizations break Flux reconciliation

## Troubleshooting

### Error: "may not add resource with an already registered id"

**Cause**: Same resource defined multiple times (e.g., two apps defining the same namespace).

**Solution**: Comment out duplicate resource in one of the kustomizations.

### Error: "no such file or directory"

**Cause**: File referenced in `resources:` doesn't exist.

**Solution**:
1. Check file path is correct
2. Ensure file is committed to git (if using Flux)
3. Check `.gitignore` isn't excluding the file

### ConfigMap Changes Not Triggering Pod Restart

**Cause**: `disableNameSuffixHash: true` prevents hash generation.

**Solution**:
1. Remove `disableNameSuffixHash: true` to enable automatic restarts, OR
2. Manually restart: `kubectl rollout restart deployment/app -n namespace`

### Patches Not Applying

**Cause**: Patch target doesn't match resource name/kind/version.

**Solution**: Verify target fields match exactly:
```bash
# View what Kustomize is building
kubectl kustomize path/to/overlay/

# Check if patch is applying
kubectl kustomize path/to/overlay/ | grep -A 20 "kind: CronJob"
```

## Examples from This Repo

| Pattern | Example | Location |
|---------|---------|----------|
| Simple App | Plex | `platform/kubernetes/plex/` |
| ConfigMap Generator | Home Automation | `platform/kubernetes/home-automation/` |
| Base + Overlays | AWS S3 Backups | `platform/kubernetes/backups/aws-s3/` |
| Excluded Secrets | Kopia | `platform/kubernetes/kopia/` |
| Shared Namespace | Kopia + S3 | `platform/kubernetes/{kopia,backups/aws-s3}` |
| Infrastructure | MetalLB | `platform/kubernetes/metallb/` |

## Related Documentation

- [Flux GitOps Overview](../gitops/flux-overview.md)
- [Making Changes to GitOps Apps](../gitops/making-changes.md)
- [Kustomize Official Docs](https://kubectl.docs.kubernetes.io/references/kustomize/)
- [Kustomize Best Practices](https://kubectl.docs.kubernetes.io/guides/config_management/components/)
