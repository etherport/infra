# Flux GitOps Overview

## What is Flux?

Flux is a GitOps operator for Kubernetes that automatically synchronizes the state of your cluster with the state defined in this Git repository. When you commit changes to this repo, Flux detects them and applies the changes to the cluster automatically.

**GitOps Philosophy**: Git is the single source of truth for cluster configuration. The cluster state should always match what's in the main branch.

## Why GitOps?

- **Declarative**: Describe the desired state, not the steps to get there
- **Version Controlled**: Every change has a commit history, author, and review
- **Automated**: No manual `kubectl apply` commands - just commit and push
- **Auditable**: Full audit trail of who changed what and when
- **Recoverable**: Easy rollback via `git revert`

## How Flux Works in This Cluster

### Architecture

```
┌─────────────┐
│   Git Repo  │  ← You commit here
│  (GitHub)   │
└──────┬──────┘
       │
       │ (1) Flux polls every 1 minute
       ↓
┌─────────────────┐
│  Flux GitRepo   │  ← Detects changes
│   Source        │
└────────┬────────┘
         │
         │ (2) Flux reconciles every 10 minutes (or on-demand)
         ↓
┌──────────────────┐
│ Flux Kustomization │  ← Applies changes to cluster
└────────┬──────────┘
         │
         │ (3) Kubernetes resources updated
         ↓
┌─────────────────┐
│   Cluster State │  ← Apps running with new config
└─────────────────┘
```

### Current GitOps Coverage

**Nearly 100% of the cluster is Flux-managed.** All 16 HelmReleases in
`clusters/wind/helm-releases/` reconcile cleanly, and the
application/infrastructure kustomizations under `platform/kubernetes/`
are all referenced from `clusters/wind/`.

**Flux-managed HelmReleases** (`clusters/wind/helm-releases/` — regenerate with
`ls`): alloy, cert-manager, cnpg, github-actions-runner (2 HelmReleases:
arc-controller + arc-runner-homelab), gpu-operator, kured, kyverno, loki,
metallb, monitoring (kube-prometheus-stack), pushgateway, tailscale-operator,
tetragon, traefik, velero. (`tailscale-connector.yaml` in the same directory is
a Flux Kustomization, not a HelmRelease.)

**Flux-managed kustomizations** (selected — see
`clusters/wind/kustomization.yaml` for the full list):
Technitium DNS, Multus NADs, Home Automation, Plex, Ollama, Wiki.js,
WireGuard, Cloudflare DDNS, Rclone (GDrive + OneDrive), backups
(Velero schedules + S3-sync shares), auto-remediation.

**Out of band (intentional)**: the Flux bootstrap itself (the
`flux-system` install was done with `flux bootstrap github`) and the
underlying Proxmox VMs / kubespray-deployed cluster (Terraform +
ansible, not GitOps).

### Directory Structure

```
homelab-infra/
├── clusters/
│   └── wind/
│       ├── flux-system/          # Flux installation
│       └── kustomization.yaml    # Main Flux config - apps to deploy
├── platform/
│   └── kubernetes/
│       ├── home-automation/      # Each app has its own directory
│       │   ├── kustomization.yaml
│       │   ├── deployment.yaml
│       │   └── ...
│       ├── plex/
│       └── ...
└── docs/
    └── gitops/                   # GitOps documentation (this file)
```

## The GitOps Workflow

### Making Changes to Flux-Managed Apps

```bash
# 1. Edit the configuration locally
vim platform/kubernetes/home-automation/configuration.yaml

# 2. (Optional) Test the kustomization locally
kubectl kustomize platform/kubernetes/home-automation/

# 3. Commit and push
git add platform/kubernetes/home-automation/configuration.yaml
git commit -m "Update home-automation: add new automation"
git push

# 4. Flux detects the change (within 1 minute)
# 5. Flux applies the change (within 10 minutes, or force with reconcile)
kubectl annotate --overwrite -n flux-system gitrepository/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
kubectl annotate --overwrite -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"

# 6. Verify the change was applied
kubectl get pods -n home-automation
```

### How Different Resource Types React

| Resource Type | What Happens | Time to Take Effect |
|--------------|--------------|---------------------|
| **Deployment** (with ConfigMap change) | New ConfigMap created with hash suffix → Pod restart | Immediate (on reconcile) |
| **Deployment** (spec change) | Rolling update triggered | Immediate (on reconcile) |
| **CronJob** | CronJob spec updated | Next scheduled run |
| **Service/Ingress** | Configuration updated | Immediate (on reconcile) |
| **ConfigMap** (standalone) | ConfigMap updated, pods must restart manually | Immediate for CM, manual for pods |

### Example: Updating Home Automation Config

```yaml
# clusters/wind/kustomization.yaml references:
- ../../platform/kubernetes/home-automation

# platform/kubernetes/home-automation/kustomization.yaml contains:
configMapGenerator:
  - name: home-assistant-config
    files:
      - configuration.yaml
```

**What happens when you edit `configuration.yaml`:**

1. You commit and push the change
2. Flux detects the change in git
3. Flux runs kustomize, which generates a new ConfigMap: `home-assistant-config-abc123xyz`
4. The Deployment sees a new ConfigMap name
5. Kubernetes triggers a rolling update
6. New pod starts with the new configuration

**No manual `kubectl apply` needed!**

## Key Flux Commands

### Check Flux Status

```bash
# Check if Flux is healthy (controllers Ready = healthy)
kubectl get pods -n flux-system

# View all GitRepositories Flux is watching
kubectl get gitrepository -n flux-system

# View all Kustomizations Flux is applying
kubectl get kustomizations -n flux-system

# View detailed status of main kustomization
kubectl get kustomizations -n flux-system -o yaml
```

### Force Reconciliation

When you don't want to wait for Flux's automatic sync:

```bash
# Force Flux to pull from git NOW
kubectl annotate --overwrite -n flux-system gitrepository/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"

# Force Flux to apply changes NOW
kubectl annotate --overwrite -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"

# Or do both in one command:
kubectl annotate --overwrite -n flux-system gitrepository/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" && \
kubectl annotate --overwrite -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
```

### Suspend/Resume Reconciliation

Useful when you need to make manual changes temporarily:

```bash
# Suspend automatic reconciliation
kubectl patch kustomization/flux-system -n flux-system --type=merge -p '{"spec":{"suspend":true}}'

# Make manual changes...
kubectl apply -f /tmp/emergency-fix.yaml

# Resume automatic reconciliation
kubectl patch kustomization/flux-system -n flux-system --type=merge -p '{"spec":{"suspend":false}}'
```

## Troubleshooting

### Flux Not Applying Changes

**Symptom**: You pushed changes but they're not showing up in the cluster.

**Steps**:
1. Check if Flux detected the git change:
   ```bash
   kubectl get gitrepository -n flux-system
   # Look for "Applied revision: main@sha1:XXXXXX"
   ```

2. Check if the kustomization is healthy:
   ```bash
   kubectl get kustomizations -n flux-system
   # Look for READY=True
   ```

3. If READY=False, check the error message:
   ```bash
   kubectl describe kustomization flux-system -n flux-system
   # Look for error messages in Events or Status
   ```

4. Common errors:
   - **"no such file or directory"**: File referenced in kustomization.yaml doesn't exist
   - **"may not add resource with an already registered id"**: Duplicate resource (e.g., same namespace defined twice)
   - **"missing Resource metadata"**: File is not a valid Kubernetes resource (missing apiVersion/kind/metadata)

### Testing Kustomization Locally

Before pushing changes, test them locally:

```bash
# Build the kustomization (dry-run)
kubectl kustomize platform/kubernetes/home-automation/

# Apply to cluster without committing (testing only)
kubectl apply --dry-run=client -k platform/kubernetes/home-automation/

# Apply for real (but this defeats GitOps - only for testing)
kubectl apply -k platform/kubernetes/home-automation/
```

### Viewing Flux Logs

```bash
# Flux source controller (watches git)
kubectl logs -n flux-system deploy/source-controller -f

# Flux kustomize controller (applies kustomizations)
kubectl logs -n flux-system deploy/kustomize-controller -f

# Flux notification controller (sends alerts)
kubectl logs -n flux-system deploy/notification-controller -f
```

## Adding New Applications to Flux

### Prerequisites

1. The app must have a `kustomization.yaml` file in its directory
2. All resources must be valid Kubernetes manifests
3. Secrets should use SOPS encryption (see [SOPS Setup](../secrets/SOPS-SETUP.md))

### Process

1. **Create the app directory structure**:
   ```bash
   mkdir -p platform/kubernetes/my-app
   cd platform/kubernetes/my-app
   ```

2. **Create Kubernetes manifests**:
   ```bash
   # Namespace, Deployment, Service, etc.
   vim 00-namespace.yaml
   vim 01-deployment.yaml
   vim 02-service.yaml
   ```

3. **Create kustomization.yaml**:
   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization

   namespace: my-app

   resources:
     - 00-namespace.yaml
     - 01-deployment.yaml
     - 02-service.yaml
   ```

4. **Test locally**:
   ```bash
   kubectl kustomize platform/kubernetes/my-app/
   ```

5. **Add to Flux kustomization**:
   ```bash
   vim clusters/wind/kustomization.yaml
   ```

   Add:
   ```yaml
   resources:
     - ../../platform/kubernetes/my-app
   ```

6. **Commit and push**:
   ```bash
   git add platform/kubernetes/my-app/
   git add clusters/wind/kustomization.yaml
   git commit -m "Add my-app to Flux"
   git push
   ```

7. **Force reconciliation and verify**:
   ```bash
   kubectl annotate --overwrite -n flux-system gitrepository/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
   kubectl annotate --overwrite -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
   kubectl get pods -n my-app
   ```

## SOPS Integration for Secrets

Flux integrates with SOPS to decrypt secrets automatically. See the full guide: [SOPS Setup](../secrets/SOPS-SETUP.md)

**Quick overview**:
1. Secrets are encrypted with SOPS using age keys
2. Flux has access to the age private key (stored as a secret)
3. Flux automatically decrypts `*.sops.yaml` files before applying them
4. Secrets never exist unencrypted in git

**Example**:
```bash
# Encrypt a secret with SOPS
sops -e secret.yaml > secret.sops.yaml

# Commit the encrypted version
git add secret.sops.yaml
git commit -m "Add encrypted secret"
git push

# Flux will decrypt it automatically when applying
```

## Best Practices

### Do's ✅

- **Always commit changes through git** - don't use `kubectl apply` for Flux-managed apps
- **Use ConfigMap generators** for config files - enables automatic pod restarts
- **Test kustomizations locally** with `kubectl kustomize` before pushing
- **Use SOPS for secrets** - never commit plaintext secrets
- **Write descriptive commit messages** - they're your audit trail
- **Trigger a reconcile after pushing** (annotate the GitRepository/Kustomization with `reconcile.fluxcd.io/requestedAt`) - don't wait 10 minutes for automatic sync

### Don'ts ❌

- **Don't use `kubectl apply` on Flux-managed resources** - changes will be reverted
- **Don't commit secrets to git unencrypted** - use SOPS
- **Don't mix manual and GitOps management** - pick one per app
- **Don't edit resources directly with `kubectl edit`** - changes will be lost
- **Don't skip testing** - broken kustomizations will break the entire Flux reconciliation

## Manual Override (Emergency Use Only)

If you need to make emergency changes that can't wait for git:

```bash
# 1. Suspend Flux
kubectl patch kustomization/flux-system -n flux-system --type=merge -p '{"spec":{"suspend":true}}'

# 2. Make your emergency change
kubectl edit deployment my-app -n my-namespace

# 3. Update git to match what you did
vim platform/kubernetes/my-app/deployment.yaml
git commit -am "Emergency fix: increase memory limit"
git push

# 4. Resume Flux
kubectl patch kustomization/flux-system -n flux-system --type=merge -p '{"spec":{"suspend":false}}'

# 5. Force reconcile to ensure git is in sync
kubectl annotate --overwrite -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
```

## Related Documentation

- [Making Changes to GitOps Apps](./making-changes.md) - Step-by-step guide
- [Kustomize Patterns](../../reference/kustomize-patterns.md) - Common patterns used in this repo
- [SOPS Setup](../secrets/SOPS-SETUP.md) - Secret encryption setup
- [Flux Official Docs](https://fluxcd.io/flux/) - Upstream documentation

## Support

If you run into issues:

1. Check Flux status: `kubectl get pods -n flux-system` (controllers Ready = healthy)
2. Check kustomization errors: `kubectl describe kustomization flux-system -n flux-system`
3. Test locally: `kubectl kustomize path/to/app/`
4. Check Flux logs: `kubectl logs -n flux-system deploy/kustomize-controller -f`
5. Review this guide's troubleshooting section above
