# Home Assistant GitOps Setup

## Overview

Home Assistant configuration is now managed via GitOps using Flux. This means you can edit configuration locally, push to git, and changes automatically sync to the cluster.

## Architecture

- **configuration.yaml**: Managed via Git → ConfigMap → mounted read-only in pod
- **automations.yaml, scripts.yaml, scenes.yaml**: Managed via Home Assistant UI → stored on PVC
- **Other data** (.storage/, database): Stored on PVC

## Workflow: Editing Configuration

### 1. Edit Locally

```bash
# Edit the configuration file
code platform/kubernetes/home-automation/configuration.yaml

# Or use any editor you prefer
vi platform/kubernetes/home-automation/configuration.yaml
```

### 2. Test the Kustomization (Optional)

```bash
kubectl kustomize platform/kubernetes/home-automation
```

### 3. Commit and Push

```bash
git add platform/kubernetes/home-automation/configuration.yaml
git commit -m "Update Home Assistant configuration"
git push
```

### 4. Flux Automatically Syncs

Flux watches the git repository and will:
1. Detect the configuration.yaml change
2. Rebuild the ConfigMap with a new hash
3. Update the deployment to use the new ConfigMap
4. Trigger a rolling restart of Home Assistant pods
5. Home Assistant loads the new configuration

**Timeline**: Changes typically apply within 1-5 minutes of pushing to git.

### 5. Manual Sync (if needed)

To force an immediate sync:

```bash
flux reconcile source git flux-system
flux reconcile kustomization home-automation
```

## Manual Application (Without Flux)

If you need to apply changes manually:

```bash
kubectl apply -k platform/kubernetes/home-automation
```

## Important Notes

⚠️ **Secrets**: The configuration.yaml currently contains secrets (passwords, API keys). Consider:
- Moving secrets to Kubernetes Secrets or Sealed Secrets
- Using environment variables for sensitive data
- Never commit real secrets to public repositories

✅ **UI-Managed Files**: Files like automations.yaml are managed through the Home Assistant UI and stored on the PVC. Don't try to manage these in git.

✅ **Pod Restart**: Changes to configuration.yaml require a pod restart. This happens automatically when using kustomize's ConfigMap generator.

## Troubleshooting

**Changes not applying?**
```bash
# Check Flux reconciliation status
flux get sources git
flux get kustomizations

# Force reconciliation
flux reconcile source git flux-system
flux reconcile kustomization home-automation
```

**Check current ConfigMap:**
```bash
kubectl get configmap -n home-automation | grep home-assistant-config
kubectl get configmap home-assistant-config-<hash> -n home-automation -o yaml
```

**View pod logs:**
```bash
kubectl logs -n home-automation -l app=home-assistant
```
