# Making Changes to GitOps-Managed Applications

This guide provides step-by-step instructions for common change scenarios in Flux-managed applications.

## Table of Contents

- [Before You Begin](#before-you-begin)
- [Scenario 1: Update Application Configuration](#scenario-1-update-application-configuration)
- [Scenario 2: Change CronJob Schedule](#scenario-2-change-cronjob-schedule)
- [Scenario 3: Update Container Image](#scenario-3-update-container-image)
- [Scenario 4: Add Environment Variable](#scenario-4-add-environment-variable)
- [Scenario 5: Scale Application](#scenario-5-scale-application)
- [Scenario 6: Test Changes Immediately (CronJob)](#scenario-6-test-changes-immediately-cronjob)
- [Rollback Changes](#rollback-changes)
- [Troubleshooting](#troubleshooting)

## Before You Begin

### Prerequisites

- Git repository cloned locally
- kubectl configured and working

> **Note:** there is **no `flux` CLI** on the ops hosts (mini or devbox). All the
> "reconcile" steps below trigger Flux via an annotation on the Flux objects
> instead — see [CLAUDE.md §3](../../../CLAUDE.md). The pattern is:
> ```bash
> kubectl annotate --overwrite -n flux-system <kind>/<name> \
>   reconcile.fluxcd.io/requestedAt="$(date +%s)"
> ```

### Check Current Flux Status

```bash
# View what Flux is currently managing (and its health/last-applied revision)
kubectl get kustomizations -n flux-system
kubectl get gitrepositories -n flux-system
```

### Identify If Your App is Flux-Managed

Check if your app is listed in the main Flux kustomization:

```bash
cat clusters/wind/kustomization.yaml
```

If your app's path appears under `resources:`, it's Flux-managed. Use this guide.

If not, use traditional `kubectl apply` commands documented in the app's README.

---

## Scenario 1: Update Application Configuration

**Example**: Change Home Assistant automation rules, update Plex settings, etc.

### Steps

1. **Locate the configuration file**:
   ```bash
   cd platform/kubernetes/home-automation/
   ls -la
   # Look for configuration.yaml, config.yaml, or similar
   ```

2. **Edit the configuration**:
   ```bash
   vim configuration.yaml
   # Make your changes
   ```

3. **Test the kustomization** (optional but recommended):
   ```bash
   kubectl kustomize . | less
   # Verify the output looks correct
   ```

4. **Commit and push**:
   ```bash
   git add configuration.yaml
   git commit -m "home-automation: add new automation for living room lights"
   git push
   ```

5. **Force Flux to sync immediately** (or wait up to 10 minutes):
   ```bash
   kubectl annotate --overwrite -n flux-system gitrepository/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
   kubectl annotate --overwrite -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
   ```

6. **Verify the change**:
   ```bash
   # For apps using ConfigMap generator (like home-automation):
   kubectl get configmaps -n home-automation
   # You should see a new configmap with a new hash

   # Check pod status
   kubectl get pods -n home-automation
   # Pod should be restarting with new config

   # View pod logs
   kubectl logs -n home-automation -l app=home-assistant -f
   ```

### How It Works

For apps using ConfigMap generators (check their `kustomization.yaml`):

1. Flux generates a new ConfigMap with a hash suffix: `app-config-abc123`
2. The Deployment references the new ConfigMap name
3. Kubernetes detects the change and triggers a rolling update
4. Old pod terminates, new pod starts with new configuration

**No manual pod restart needed!**

---

## Scenario 2: Change CronJob Schedule

**Example**: Change Cloudflare DDNS from hourly to every 30 minutes.

### Steps

1. **Find the CronJob manifest**:
   ```bash
   cd platform/kubernetes/cloudflare-ddns/base/
   vim cronjob.yaml
   ```

2. **Update the schedule**:
   ```yaml
   spec:
     schedule: "*/30 * * * *"  # Every 30 minutes
     # Was: "0 * * * *"  # Every hour
   ```

3. **Commit and push**:
   ```bash
   git add cronjob.yaml
   git commit -m "cloudflare-ddns: update schedule to every 30 minutes"
   git push
   ```

4. **Force reconciliation**:
   ```bash
   kubectl annotate --overwrite -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
   ```

5. **Verify the change**:
   ```bash
   kubectl get cronjob -n cloudflare-ddns
   # Check the SCHEDULE column
   ```

### Important Note

The CronJob spec is updated immediately, but the **new schedule only takes effect for future runs**. Any currently running job uses the old schedule.

To test immediately, see [Scenario 6](#scenario-6-test-changes-immediately-cronjob).

---

## Scenario 3: Update Container Image

**Example**: Update Plex to a newer version.

### Steps

1. **Find the deployment**:
   ```bash
   cd platform/kubernetes/plex/
   vim 02-deployment.yaml
   ```

2. **Update the image tag**:
   ```yaml
   spec:
     containers:
     - name: plex
       image: ghcr.io/linuxserver/plex:1.40.0.7998
       # Was: ghcr.io/linuxserver/plex:1.39.0.7123
   ```

3. **Commit and push**:
   ```bash
   git add 02-deployment.yaml
   git commit -m "plex: update to version 1.40.0.7998"
   git push
   ```

4. **Force reconciliation**:
   ```bash
   kubectl annotate --overwrite -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
   ```

5. **Watch the rolling update**:
   ```bash
   kubectl rollout status deployment/plex -n plex

   # Watch pod events
   kubectl get events -n plex --sort-by='.lastTimestamp' -w
   ```

6. **Verify new version**:
   ```bash
   kubectl get pod -n plex -o jsonpath='{.items[0].spec.containers[0].image}'
   ```

### Rollback If Needed

If the new version has issues:

```bash
# Option 1: Git revert
git revert HEAD
git push
kubectl annotate --overwrite -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"

# Option 2: Kubectl rollback (temporary - will be reverted by Flux)
kubectl rollout undo deployment/plex -n plex
```

---

## Scenario 4: Add Environment Variable

**Example**: Add a new environment variable to the rclone Google Drive sync CronJob.

### Steps

1. **Find the manifest**:
   ```bash
   cd platform/kubernetes/rclone-gdrive/
   vim 02-cronjob.yaml
   ```

2. **Add the environment variable**:
   ```yaml
   spec:
     jobTemplate:
       spec:
         template:
           spec:
             containers:
             - name: rclone
               env:
               - name: TZ
                 value: "America/Los_Angeles"
               - name: NEW_VARIABLE  # <-- Add this
                 value: "new_value"
   ```

3. **Commit and push**:
   ```bash
   git add 02-cronjob.yaml
   git commit -m "rclone-gdrive: add NEW_VARIABLE environment variable"
   git push
   ```

4. **Force reconciliation**:
   ```bash
   kubectl annotate --overwrite -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
   ```

5. **Verify** (for CronJobs, create a test job):
   ```bash
   kubectl create job --from=cronjob/gdrive-sync gdrive-sync-test -n rclone
   kubectl logs job/gdrive-sync-test -n rclone
   # Check that the new variable appears in the environment
   ```

---

## Scenario 5: Scale Application

**Example**: Increase Plex replicas from 1 to 2 (note: Plex doesn't support this, but the pattern applies to stateless apps).

### Steps

1. **Find the deployment**:
   ```bash
   cd platform/kubernetes/plex/
   vim 02-deployment.yaml
   ```

2. **Update replicas**:
   ```yaml
   spec:
     replicas: 2  # Was: 1
   ```

3. **Commit and push**:
   ```bash
   git add 02-deployment.yaml
   git commit -m "plex: scale to 2 replicas"
   git push
   ```

4. **Force reconciliation**:
   ```bash
   kubectl annotate --overwrite -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
   ```

5. **Watch scaling**:
   ```bash
   kubectl get pods -n plex -w
   ```

### Important Note

Flux manages the desired state. If you manually scale with `kubectl scale`, Flux will revert your change on the next reconciliation!

---

## Scenario 6: Test Changes Immediately (CronJob)

**Example**: You changed the Cloudflare DDNS script and want to test it now instead of waiting for the next schedule.

### Steps

1. **Make your changes** (follow Scenario 1 or 2 above)

2. **Wait for Flux to reconcile** or force it:
   ```bash
   kubectl annotate --overwrite -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
   ```

3. **Create a manual job from the CronJob**:
   ```bash
   kubectl create job --from=cronjob/cloudflare-ddns ddns-test-$(date +%s) -n cloudflare-ddns
   ```

4. **Watch the test job**:
   ```bash
   kubectl get jobs -n cloudflare-ddns -w
   ```

5. **Check logs**:
   ```bash
   kubectl logs -n cloudflare-ddns job/ddns-test-1234567890
   ```

6. **Clean up test job** (optional):
   ```bash
   kubectl delete job ddns-test-1234567890 -n cloudflare-ddns
   ```

---

## Rollback Changes

### Option 1: Git Revert (Recommended)

```bash
# Find the commit to revert
git log --oneline

# Revert the problematic commit
git revert <commit-hash>

# Push the revert
git push

# Force Flux to apply
kubectl annotate --overwrite -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
```

### Option 2: Git Reset (Destructive)

```bash
# Reset to previous commit (WARNING: loses commits)
git reset --hard HEAD~1

# Force push (WARNING: rewrites history)
git push --force

# Force Flux to apply
kubectl annotate --overwrite -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
```

### Option 3: Emergency Manual Rollback

If git is unavailable:

```bash
# Suspend Flux (so it stops re-applying git while you hand-fix)
kubectl patch kustomization/flux-system -n flux-system --type=merge -p '{"spec":{"suspend":true}}'

# Manual rollback (for Deployments)
kubectl rollout undo deployment/my-app -n my-namespace

# Fix the issue in git
vim platform/kubernetes/my-app/deployment.yaml
git commit -am "Fix deployment issue"
git push

# Resume Flux + reconcile
kubectl patch kustomization/flux-system -n flux-system --type=merge -p '{"spec":{"suspend":false}}'
kubectl annotate --overwrite -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
```

---

## Troubleshooting

### Change Not Applying

**Problem**: Pushed changes but nothing happens in the cluster.

**Solution**:

1. Check if Flux detected the git change:
   ```bash
   kubectl get gitrepository/flux-system -n flux-system -o jsonpath='{.status.artifact.revision}'
   # Look for the latest commit SHA
   ```

2. Force reconciliation:
   ```bash
   kubectl annotate --overwrite -n flux-system gitrepository/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
   kubectl annotate --overwrite -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
   ```

3. Check for errors:
   ```bash
   kubectl get kustomizations -n flux-system
   kubectl describe kustomization flux-system -n flux-system
   ```

### ConfigMap Not Updating Pods

**Problem**: ConfigMap changed but pods still use old config.

**Solution**:

If the app doesn't use ConfigMap generators (check `kustomization.yaml`):

```bash
# Manual pod restart needed
kubectl rollout restart deployment/my-app -n my-namespace
```

Better: Update the app to use ConfigMap generators so restarts happen automatically.

### Kustomization Build Failed

**Problem**: Flux shows error "kustomize build failed".

**Solution**:

1. Test locally:
   ```bash
   kubectl kustomize platform/kubernetes/my-app/
   ```

2. Common errors:
   - File referenced in `kustomization.yaml` doesn't exist
   - Duplicate resource (same namespace defined twice)
   - Invalid YAML syntax

3. Fix the issue, commit, and push

### Manual Change Reverted by Flux

**Problem**: Made a change with `kubectl edit` but it disappeared.

**Solution**:

This is expected! Flux enforces git as the source of truth. To make the change permanent:

1. Update the file in git
2. Commit and push
3. Let Flux apply it

If you need to make emergency manual changes, see [Emergency Manual Rollback](#option-3-emergency-manual-rollback).

---

## Best Practices Checklist

- [ ] Test kustomization locally with `kubectl kustomize` before pushing
- [ ] Write descriptive commit messages
- [ ] Force reconcile after pushing to verify changes immediately
- [ ] For CronJobs, test with a manual job creation
- [ ] For Deployments, watch rollout status
- [ ] Check pod logs after changes apply
- [ ] Never use `kubectl edit` on Flux-managed resources
- [ ] Always update git, not the cluster directly

---

## Related Documentation

- [Flux GitOps Overview](./flux-overview.md) - Conceptual overview
- [Kustomize Patterns](../../reference/kustomize-patterns.md) - Common patterns used
- [SOPS Setup](../secrets/SOPS-SETUP.md) - Managing secrets

## Quick Reference Commands

```bash
# Force Flux to sync NOW (no flux CLI on the hosts — annotate the objects)
kubectl annotate --overwrite -n flux-system gitrepository/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
kubectl annotate --overwrite -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"

# Check Flux status
kubectl get kustomizations -n flux-system
kubectl get gitrepositories -n flux-system

# Test kustomization locally
kubectl kustomize path/to/app/

# Create test job from CronJob
kubectl create job --from=cronjob/NAME test-NAME -n NAMESPACE

# Watch deployment rollout
kubectl rollout status deployment/NAME -n NAMESPACE

# View recent events
kubectl get events -n NAMESPACE --sort-by='.lastTimestamp'

# Rollback deployment (temporary - Flux will revert)
kubectl rollout undo deployment/NAME -n NAMESPACE
```
