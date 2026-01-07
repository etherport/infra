# TODO: Migrate Exclude Patterns to Kustomize-Generated ConfigMaps

**Status**: Planned, not yet implemented
**Priority**: Medium
**Estimated Time**: 30-45 minutes
**When**: When you have time, not urgent

## Context

### Current Problem
Each S3 sync share has its own ConfigMap for exclude patterns, and they must be manually synced:
- `aws-s3-sync-excludes-global` (general, used by flux)
- `s3-sync-graham-aws-s3-sync-excludes-global`
- `s3-sync-archive-aws-s3-sync-excludes-global`
- `s3-sync-backups-aws-s3-sync-excludes-global`
- `s3-sync-mark-aws-s3-sync-excludes-global`
- `s3-sync-media-aws-s3-sync-excludes-global`
- `s3-sync-content-aws-s3-sync-excludes-global`
- `s3-sync-scans-aws-s3-sync-excludes-global` (suspended - test data only)

### What Went Wrong (January 5, 2026)
1. Updated `platform/kubernetes/backups/aws-s3/base/excludes-global.txt` with new patterns
2. Flux updated `aws-s3-sync-excludes-global` ConfigMap automatically
3. But the 7 share-specific ConfigMaps had STALE data (8 days old)
4. Archive sync uploaded `.smbdelete` files because they weren't excluded
5. Had to manually update all 7 ConfigMaps with a script

### Solution: Kustomize ConfigMapGenerator
Use Kustomize to **generate all ConfigMaps from the base file** automatically.

## Implementation Steps

### 1. Update Kustomization File
**File**: `platform/kubernetes/backups/aws-s3/base/kustomization.yaml`

Add `configMapGenerator` section:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  # ... existing resources ...

configMapGenerator:
- name: s3-sync-graham-aws-s3-sync-excludes-global
  files:
  - excludes-global.txt
  behavior: replace

- name: s3-sync-archive-aws-s3-sync-excludes-global
  files:
  - excludes-global.txt
  behavior: replace

- name: s3-sync-backups-aws-s3-sync-excludes-global
  files:
  - excludes-global.txt
  behavior: replace

- name: s3-sync-mark-aws-s3-sync-excludes-global
  files:
  - excludes-global.txt
  behavior: replace

- name: s3-sync-media-aws-s3-sync-excludes-global
  files:
  - excludes-global.txt
  behavior: replace

- name: s3-sync-content-aws-s3-sync-excludes-global
  files:
  - excludes-global.txt
  behavior: replace

- name: s3-sync-scans-aws-s3-sync-excludes-global
  files:
  - excludes-global.txt
  behavior: replace

# Optional: Keep general ConfigMap for reference
- name: aws-s3-sync-excludes-global
  files:
  - excludes-global.txt
  behavior: replace
```

### 2. Test Locally
```bash
cd /Users/grahamsmith/Projects/homelab-infra/platform/kubernetes/backups/aws-s3/base

# Build and check generated manifests
kustomize build . | grep -A 10 "kind: ConfigMap"

# Verify each ConfigMap has the correct content
kustomize build . | yq eval 'select(.kind == "ConfigMap") | .metadata.name' -
```

### 3. Commit and Push
```bash
cd /Users/grahamsmith/Projects/homelab-infra
git add platform/kubernetes/backups/aws-s3/base/kustomization.yaml
git commit -m "Add Kustomize configMapGenerator for exclude patterns

- Generates all share-specific ConfigMaps from base excludes-global.txt
- Ensures all shares stay in sync automatically
- Prevents stale ConfigMap issues like the one on 2026-01-05"
git push
```

### 4. Wait for Flux to Apply
```bash
# Check flux reconciliation
flux get kustomizations -A

# Force reconciliation if needed
flux reconcile kustomization flux-system -n flux-system

# Verify all ConfigMaps updated
kubectl get configmaps -n backups | grep excludes-global
kubectl get configmap -n backups s3-sync-graham-aws-s3-sync-excludes-global -o yaml | grep -A 5 "excludes-global.txt:"
```

### 5. Verify Pattern Count
```bash
for share in graham archive backups mark media content scans; do
  COUNT=$(kubectl get configmap -n backups "s3-sync-${share}-aws-s3-sync-excludes-global" \
    -o jsonpath='{.data.excludes-global\.txt}' | grep -v '^#' | grep -v '^$' | wc -l | awk '{print $1}')
  echo "$share: $COUNT patterns"
done
```

Expected output (as of 2026-01-06):
```
graham: 44 patterns
archive: 44 patterns
backups: 44 patterns
mark: 44 patterns
media: 44 patterns
content: 44 patterns
scans: 44 patterns (if re-enabled)
```

### 6. Test with Manual Sync
Run a validation sync to ensure everything works:
```bash
# Create and run test job for one share
kubectl create job -n backups test-excludes-graham \
  --from=cronjob/s3-sync-graham-s3-sync-template

# Wait for completion
kubectl wait --for=condition=complete job/test-excludes-graham -n backups --timeout=5m

# Check logs
kubectl logs -n backups job/test-excludes-graham | grep "patterns loaded"
# Should show: [excludes] Total patterns loaded: 44

# Check results
kubectl logs -n backups job/test-excludes-graham | grep "Files uploaded"
# Should show: Files uploaded/copied: 0

# Cleanup
kubectl delete job -n backups test-excludes-graham
```

## Benefits

1. **Single Source of Truth**: Only edit `excludes-global.txt`
2. **Automatic Sync**: Kustomize generates all ConfigMaps from one file
3. **No Manual Updates**: Flux applies changes automatically
4. **Future-Proof**: Easy to add share-specific patterns later (create separate files)

## Future Enhancement: Share-Specific Patterns

If you need share-specific exclusions later, you can:

1. Create `platform/kubernetes/backups/aws-s3/base/excludes-graham.txt`
2. Update kustomization for that share:
   ```yaml
   - name: s3-sync-graham-aws-s3-sync-excludes-global
     files:
     - excludes-global.txt
     - excludes-graham.txt
     behavior: replace
   ```

## Rollback Plan

If something goes wrong:
```bash
# Revert the kustomization.yaml change
git revert <commit-hash>
git push

# Force Flux to reconcile
flux reconcile kustomization flux-system -n flux-system

# Or manually recreate ConfigMaps from the excludes file:
EXCLUDES_FILE="platform/kubernetes/backups/aws-s3/base/excludes-global.txt"
for SHARE in graham archive backups mark media content scans; do
  kubectl create configmap -n backups "s3-sync-${SHARE}-aws-s3-sync-excludes-global" \
    --from-file=excludes-global.txt="$EXCLUDES_FILE" \
    --dry-run=client -o yaml | kubectl apply -f -
done
```

## Current Status (as of 2026-01-06)

- ✅ All share ConfigMaps manually updated to 44 patterns (added `*.braw` exclusion)
- ✅ Validation syncs completed: 0 files uploaded across all 7 shares
- ✅ `.smbdelete` files removed from S3
- ✅ Scans cronjob suspended (test data only, cleaned up from S3)
- ✅ Nightly backups running successfully (6 active shares)
- ⏳ Kustomize migration: **Planned, not yet implemented**

## Files to Review

- `platform/kubernetes/backups/aws-s3/base/kustomization.yaml` - Add configMapGenerator here
- `platform/kubernetes/backups/aws-s3/base/excludes-global.txt` - Source file (44 patterns)

## Questions?

If you're unsure about anything, check:
1. Git commits from 2026-01-05 and 2026-01-06 that updated exclude patterns
2. The `excludes-global.txt` file for current patterns (44 as of 2026-01-06)
3. This TODO document

---

**Created**: 2026-01-05
**Last Updated**: 2026-01-06
**Assigned To**: Future Agent / When Time Permits
