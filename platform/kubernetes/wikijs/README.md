# Wiki.js

Wiki.js is a modern, powerful wiki app built on Node.js.

## Architecture

```
Internet → AWS ALB → VPN → Traefik (10.10.201.70)
                              ↓
                     IngressRoute (wiki.wind.etherport.net)
                              ↓
                     wiki-js Service (ClusterIP)
                              ↓
                     Wiki.js Deployment
                              ↓
                     postgres-cluster-rw.postgres:5432
```

## Prerequisites

- CloudNativePG operator installed (Helm)
- PostgreSQL cluster running with `wikijs` database
- Traefik ingress controller
- Flux with SOPS decryption enabled

## Installation

### 1. Ensure PostgreSQL is Ready

```bash
# Verify cluster is running
kubectl get cluster -n postgres
kubectl get pods -n postgres

# Should show postgres-cluster-1 as Running
```

### 2. Create and Encrypt Secrets

The password must match the one used for `postgres-app-credentials` in the cnpg namespace:

```bash
cd platform/kubernetes/wikijs

# Edit the secret file
# Replace PLACEHOLDER_MUST_MATCH_POSTGRES_CREDENTIALS with the same password
vim 02-db-secret.sops.yaml

# Encrypt with SOPS
sops -e -i 02-db-secret.sops.yaml
```

### 3. Deploy via Flux

Wiki.js is deployed automatically by Flux after secrets are encrypted and pushed:

```bash
git add -A
git commit -m "Add Wiki.js with encrypted database credentials"
git push

# Flux will reconcile automatically, or force sync:
flux reconcile kustomization flux-system
```

### 4. Verify Deployment

```bash
# Check pod status
kubectl get pods -n wikijs

# Check logs
kubectl logs -n wikijs -l app=wiki-js

# Check ingress
kubectl get ingressroute -n wikijs
```

### 5. Initial Setup

1. Navigate to https://wiki.wind.etherport.net
2. Complete the setup wizard
3. Create admin account
4. Configure site settings

## Configuration

### Environment Variables

Key environment variables in deployment:

| Variable | Value | Description |
|----------|-------|-------------|
| DB_TYPE | postgres | Database type |
| DB_HOST | postgres-cluster-rw.postgres | CloudNativePG service |
| DB_PORT | 5432 | PostgreSQL port |
| DB_NAME | wikijs | Database name |
| DB_USER | wikijs | Database user |

### Storage

- **PVC**: 5Gi on ceph-rbd for uploads and local assets
- **Database**: Managed by CloudNativePG cluster

## Upgrades

Edit the image tag in `03-deployment.yaml`:

```yaml
image: ghcr.io/requarks/wiki:2.5
```

Commit and push - Flux handles the rollout:

```bash
git add -A
git commit -m "Upgrade Wiki.js to 2.5"
git push
```

Or restart to pull latest `:2` tag:

```bash
kubectl rollout restart deployment/wiki-js -n wikijs
```

## Troubleshooting

### Pod not starting

```bash
# Check events
kubectl describe pod -n wikijs -l app=wiki-js

# Check database connectivity
kubectl exec -n wikijs -it deploy/wiki-js -- nc -zv postgres-cluster-rw.postgres 5432
```

### Database connection issues

```bash
# Verify PostgreSQL cluster
kubectl get cluster -n postgres

# Check secret exists and is decrypted
kubectl get secret -n wikijs wiki-js-db-credentials

# View secret (base64 encoded)
kubectl get secret -n wikijs wiki-js-db-credentials -o jsonpath='{.data.DB_PASS}' | base64 -d
```

### Flux not deploying

```bash
# Check Flux status
flux get kustomization flux-system

# View Flux logs
flux logs --all-namespaces

# Check for SOPS decryption errors
kubectl logs -n flux-system deploy/kustomize-controller | grep -i sops
```

## Backup

Wiki.js data is stored in:
1. **PostgreSQL database** - Backed up via CloudNativePG (if configured) or Velero
2. **Uploads PVC** - Backed up via Velero

## Resources

- [Wiki.js Documentation](https://docs.requarks.io/)
- [Wiki.js Docker](https://docs.requarks.io/install/docker)
- [CloudNativePG](https://cloudnative-pg.io/)
