# Kopia (Kubernetes)

Deploys Kopia Server in-cluster with:
- Persistent Kopia repository on Ceph PVC
- Persistent Kopia config/cache on Ceph PVC
- Traefik IngressRoute at `https://kopia.wind.etherport.net` (TLS via Route53 DNS-01)

**Deployment Method**: This application is managed via **Flux GitOps**. Changes are deployed automatically from git commits.

## Files
- `00-namespace.yaml` — namespace `backups` (shared with AWS S3 backups, namespace not in kustomization - defined elsewhere)
- `01-pvc-repo.yaml` — PVC for Kopia repository (`/repo`)
- `02-pvc-config.yaml` — PVC for Kopia config/cache
- `03-secret-template.yaml` — template only (not deployed via GitOps - create manually)
- `04-configmap-entrypoint.yaml` — idempotent repo init/connect + server start
- `05-deployment.yaml` — Kopia server deployment
- `06-service.yaml` — ClusterIP service
- `07-ingressroute.yaml` — Traefik IngressRoute (`websecure`, `route53` resolver)
- `kustomization.yaml` — Kustomize configuration for Flux

## Prerequisites

1. **Traefik installed** and working with `certResolver: route53`
2. **DNS**: `kopia.wind.etherport.net` points to your Traefik LB IP (MetalLB VIP)
3. **StorageClass**: Default is Ceph (or set `storageClassName` explicitly in PVCs)
4. **Kopia Credentials Secret**: Must be created manually before deployment

Check storage classes:
```bash
kubectl get storageclass
```

### Create Credentials Secret

Create the secret manually (not managed by GitOps):

```bash
kubectl -n backups create secret generic kopia-credentials \
  --from-literal=KOPIA_PASSWORD='YOUR_REPO_PASSWORD' \
  --from-literal=KOPIA_SERVER_USER='admin' \
  --from-literal=KOPIA_SERVER_PASS='YOUR_UI_PASSWORD'
```

## Deployment

### GitOps Deployment (Recommended)

This application is managed by Flux. To deploy or make changes:

1. **Ensure secret exists** (see Prerequisites above)

2. **Changes are auto-deployed from git**:
   ```bash
   # Edit any configuration file
   vim platform/kubernetes/apps/kopia/05-deployment.yaml

   # Commit and push
   git add platform/kubernetes/apps/kopia/05-deployment.yaml
   git commit -m "kopia: update deployment configuration"
   git push

   # Force Flux to sync immediately (or wait ~10 minutes)
   flux reconcile source git flux-system
   flux reconcile kustomization flux-system
   ```

3. **Verify deployment**:
   ```bash
   kubectl -n backups get pvc
   kubectl -n backups get pods -o wide
   kubectl -n backups logs deploy/kopia --tail=200
   ```

See [Flux GitOps Overview](../../../docs/gitops/flux-overview.md) for more details.

### Manual Deployment (Not Recommended)

If you need to bypass GitOps (not recommended for production):

```bash
# Deploy via kustomize
kubectl apply -k platform/kubernetes/apps/kopia/

# Or deploy individual files (legacy method):
kubectl apply -f platform/kubernetes/apps/kopia/01-pvc-repo.yaml
kubectl apply -f platform/kubernetes/apps/kopia/02-pvc-config.yaml
kubectl apply -f platform/kubernetes/apps/kopia/04-configmap-entrypoint.yaml
kubectl apply -f platform/kubernetes/apps/kopia/05-deployment.yaml
kubectl apply -f platform/kubernetes/apps/kopia/06-service.yaml
kubectl apply -f platform/kubernetes/apps/kopia/07-ingressroute.yaml
```

**Note**: Manual changes will be reverted by Flux on the next reconciliation. Always update git for persistent changes.

## Access

Open in your browser:
- **URL**: https://kopia.wind.etherport.net
- **Username**: Value of `KOPIA_SERVER_USER` from secret (default: `admin`)
- **Password**: Value of `KOPIA_SERVER_PASS` from secret

## Making Changes

### Update Container Image

```bash
# Edit deployment
vim platform/kubernetes/apps/kopia/05-deployment.yaml

# Change image tag
image: kopia/kopia:0.15.0  # Pin to specific version

# Commit and push
git add platform/kubernetes/apps/kopia/05-deployment.yaml
git commit -m "kopia: pin image to v0.15.0"
git push

# Force reconciliation
flux reconcile kustomization flux-system

# Watch rollout
kubectl rollout status deployment/kopia -n backups
```

### Update Configuration

```bash
# Edit entrypoint script
vim platform/kubernetes/apps/kopia/04-configmap-entrypoint.yaml

# Make your changes

# Commit and push
git add platform/kubernetes/apps/kopia/04-configmap-entrypoint.yaml
git commit -m "kopia: update entrypoint configuration"
git push

# Force reconciliation
flux reconcile kustomization flux-system

# Restart deployment to pick up ConfigMap change
kubectl rollout restart deployment/kopia -n backups
```

## Upgrading

To upgrade Kopia to a newer version:

```bash
# Update image tag in deployment
vim platform/kubernetes/apps/kopia/05-deployment.yaml

# Change:
# image: kopia/kopia:latest
# To:
# image: kopia/kopia:0.16.0

# Commit and push
git add platform/kubernetes/apps/kopia/05-deployment.yaml
git commit -m "kopia: upgrade to v0.16.0"
git push

# Force reconciliation
flux reconcile kustomization flux-system

# Monitor rollout
kubectl rollout status deployment/kopia -n backups
kubectl logs -n backups deploy/kopia --tail=100 -f
```