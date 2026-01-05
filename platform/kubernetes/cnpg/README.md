# CloudNativePG - PostgreSQL Operator

CloudNativePG is a Kubernetes operator for managing PostgreSQL clusters with high availability, automated failover, and declarative backups.

## Architecture

```
cnpg-system namespace (operator - Helm managed)
└── cloudnative-pg controller

postgres namespace (Flux managed)
└── Cluster CRD → PostgreSQL pods
    ├── primary (read-write)
    └── replicas (read-only, optional)
```

## Prerequisites

- Flux with SOPS decryption enabled
- `sops-age` secret in flux-system namespace
- Ceph RBD storage class

## Installation

### 1. Install CloudNativePG Operator (Helm)

The operator is installed via Helm (not Flux-managed):

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update

helm upgrade --install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system \
  --create-namespace \
  --version 0.22.1 \
  -f platform/kubernetes/cnpg/operator-values.yaml
```

### 2. Verify Operator

```bash
# Check operator pod
kubectl get pods -n cnpg-system

# Check CRDs installed
kubectl get crd | grep cnpg
```

### 3. Create and Encrypt Secrets

Secrets are managed with SOPS and age encryption. The `.sops.yaml` in this directory
configures automatic encryption for `*.sops.yaml` files using the cluster's age key.

```bash
cd platform/kubernetes/cnpg

# Generate secure password
PASSWORD=$(openssl rand -base64 24)
echo "Password: $PASSWORD"

# Edit the secret file with your password
# Replace PLACEHOLDER_GENERATE_SECURE_PASSWORD with $PASSWORD
vim 02-credentials.sops.yaml

# Encrypt with SOPS (must run from this directory to pick up .sops.yaml config)
sops -e -i 02-credentials.sops.yaml

# To view/edit encrypted secrets later:
sops 02-credentials.sops.yaml
```

**Note:** Flux automatically decrypts SOPS secrets during deployment using the
`sops-age` secret in the `flux-system` namespace. No manual decryption needed.

### 4. Deploy PostgreSQL Cluster (Flux)

The cluster is deployed automatically by Flux after secrets are encrypted and pushed:

```bash
git add -A
git commit -m "Add CloudNativePG cluster with encrypted credentials"
git push

# Flux will reconcile automatically, or force sync:
flux reconcile kustomization flux-system
```

### 5. Verify Cluster

```bash
# Check cluster status
kubectl get cluster -n postgres

# Check pods
kubectl get pods -n postgres

# View cluster details
kubectl describe cluster postgres-cluster -n postgres
```

## Usage

### Connecting Applications

Applications connect using the cluster's read-write service:

```yaml
env:
  - name: DATABASE_URL
    value: "postgresql://wikijs:password@postgres-cluster-rw.postgres:5432/wikijs"
```

Service naming convention:
- `<cluster>-rw` - Read-write (primary)
- `<cluster>-ro` - Read-only (replicas)
- `<cluster>-r` - Any replica

### Creating Additional Databases

Connect to primary and create databases manually:

```bash
# Connect to primary
kubectl exec -it postgres-cluster-1 -n postgres -- psql -U postgres

# Create database
CREATE DATABASE myapp;
CREATE USER myapp_user WITH PASSWORD 'secure_password';
GRANT ALL PRIVILEGES ON DATABASE myapp TO myapp_user;
\c myapp
GRANT ALL ON SCHEMA public TO myapp_user;
```

## Cluster Management

```bash
# View cluster status
kubectl get cluster -n postgres

# View pods
kubectl get pods -n postgres -l cnpg.io/cluster=postgres-cluster

# View logs
kubectl logs -n postgres postgres-cluster-1

# Connect to PostgreSQL
kubectl exec -it postgres-cluster-1 -n postgres -- psql -U postgres
```

## Upgrades

### Upgrade Operator

```bash
helm repo update
helm upgrade cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system \
  -f platform/kubernetes/cnpg/operator-values.yaml
```

### Upgrade PostgreSQL Version

Edit `01-cluster.yaml` and update imageName:

```yaml
spec:
  imageName: ghcr.io/cloudnative-pg/postgresql:16.4
```

Commit and push - Flux handles the rolling update.

## Backup Configuration (Optional)

To enable S3 backups, add to cluster spec:

```yaml
spec:
  backup:
    barmanObjectStore:
      destinationPath: s3://bucket/postgres
      s3Credentials:
        accessKeyId:
          name: s3-creds
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: s3-creds
          key: ACCESS_SECRET_KEY
    retentionPolicy: "30d"
```

## Resources

- [CloudNativePG Documentation](https://cloudnative-pg.io/documentation/)
- [Helm Chart](https://github.com/cloudnative-pg/charts)
- [GitHub](https://github.com/cloudnative-pg/cloudnative-pg)
