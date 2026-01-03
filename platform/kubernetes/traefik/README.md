# Traefik IngressRoute Configurations

Custom IngressRoute configurations for Traefik reverse proxy.

**Deployment Method**: These configurations are managed via **Flux GitOps**. Changes are deployed automatically from git commits.

## Overview

This directory contains IngressRoute configurations for services that need custom routing beyond standard Ingress resources. The Traefik controller itself is installed via Helm (not managed by Flux), but these IngressRoutes **are** Flux-managed.

- **Traefik Installation**: Managed via Helm (see `traefik-values.yaml`)
- **IngressRoute Configuration**: Managed via Flux GitOps (this directory)
- **Namespace**: `traefik`

## Files

| File | Purpose |
|------|---------|
| `ingressroute-infrastructure.yaml` | IngressRoutes for UPS and PDU web UIs with self-signed cert bypass |
| `ingressroute-proxmox.yaml` | IngressRoute for Proxmox VE web UI (HTTPS passthrough) |
| `kustomization.yaml` | Kustomize configuration for Flux |
| `traefik-values.yaml` | Helm values for Traefik installation (reference only, not applied by Flux) |
| `pvc-traefik-ceph.yaml` | PVC for ACME certificates (reference, applied separately) |

## Managed IngressRoutes

### Infrastructure Management

Provides HTTPS access to infrastructure devices with self-signed certificates:

- **ups1.wind.etherport.net** → `10.10.200.10:443` (UPS 1 web UI)
- **ups2.wind.etherport.net** → `10.10.200.11:443` (UPS 2 web UI)
- **pdu1.wind.etherport.net** → `10.10.200.15:443` (PDU 1 web UI)
- **pdu2.wind.etherport.net** → `10.10.200.16:443` (PDU 2 web UI)

**Special Configuration**: Uses `ServersTransport` with `insecureSkipVerify: true` to bypass self-signed certificate validation on backend devices.

### Proxmox VE

Provides HTTPS access to Proxmox hypervisors:

- **proxmox1.wind.etherport.net** → Proxmox node (HTTPS passthrough)
- **proxmox2.wind.etherport.net** → Proxmox node (HTTPS passthrough)

**Architecture**:
```
┌──────────────────┐
│  External User   │
│  (web browser)   │
└────────┬─────────┘
         │ HTTPS (valid cert from Route53)
         ↓
┌──────────────────┐
│  Traefik         │
│  (LoadBalancer)  │
└────────┬─────────┘
         │
         ├──→ UPS/PDU (insecureSkipVerify)
         │
         └──→ Proxmox (HTTPS passthrough)
```

## Traefik Installation

The Traefik controller itself is installed via Helm:

```bash
# Add Traefik Helm repo
helm repo add traefik https://traefik.github.io/charts
helm repo update

# Install Traefik (one-time)
helm install traefik traefik/traefik \
  -n traefik \
  --create-namespace \
  -f platform/kubernetes/traefik/traefik-values.yaml
```

**Important**: The Helm installation is **not** managed by Flux. Only the IngressRoutes in this directory are Flux-managed.

## Deployment

### GitOps Deployment (Recommended)

IngressRoutes are managed by Flux. Changes are auto-deployed from git:

```bash
# Edit IngressRoute configuration
vim platform/kubernetes/traefik/ingressroute-infrastructure.yaml

# Example: Add new infrastructure device
---
apiVersion: v1
kind: Service
metadata:
  name: switch1-external
  namespace: traefik
spec:
  type: ExternalName
  externalName: 10.10.200.20
  ports:
    - port: 443
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: switch1
  namespace: traefik
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`switch1.wind.etherport.net`)
      kind: Rule
      services:
        - name: switch1-external
          port: 443
          serversTransport: insecure-transport
  tls:
    certResolver: route53

# Commit and push
git add platform/kubernetes/traefik/ingressroute-infrastructure.yaml
git commit -m "traefik: add IngressRoute for switch1"
git push

# Force Flux to sync immediately (or wait ~10 minutes)
flux reconcile source git flux-system
flux reconcile kustomization flux-system

# Verify
kubectl get ingressroute -n traefik
```

See [Flux GitOps Overview](../../docs/gitops/flux-overview.md) for more details.

### Manual Deployment (Not Recommended)

If you need to bypass GitOps (changes will be reverted by Flux):

```bash
kubectl apply -k platform/kubernetes/traefik/
```

## Making Changes

### Add New IngressRoute

```bash
# 1. Edit the appropriate file
vim platform/kubernetes/traefik/ingressroute-infrastructure.yaml

# 2. Add Service + IngressRoute (see examples above)

# 3. Commit and push
git add platform/kubernetes/traefik/ingressroute-infrastructure.yaml
git commit -m "traefik: add IngressRoute for <device>"
git push

# 4. Force reconciliation
flux reconcile kustomization flux-system

# 5. Verify
kubectl get ingressroute -n traefik
kubectl describe ingressroute <name> -n traefik

# 6. Test
curl -I https://<domain>.wind.etherport.net
```

### Update Existing IngressRoute

```bash
# Edit the file
vim platform/kubernetes/traefik/ingressroute-infrastructure.yaml

# Make your changes (e.g., change backend IP, add middleware)

# Commit and push
git add platform/kubernetes/traefik/ingressroute-infrastructure.yaml
git commit -m "traefik: update <route> configuration"
git push

# Force reconciliation
flux reconcile kustomization flux-system
```

## Verification

### Check IngressRoutes

```bash
# List all IngressRoutes
kubectl get ingressroute -n traefik

# Describe specific route
kubectl describe ingressroute ups1 -n traefik

# Check Traefik logs
kubectl logs -n traefik -l app.kubernetes.io/name=traefik -f
```

### Test Routes

```bash
# Test HTTPS access
curl -I https://ups1.wind.etherport.net
curl -I https://proxmox1.wind.etherport.net

# Check certificate
openssl s_client -connect ups1.wind.etherport.net:443 -servername ups1.wind.etherport.net < /dev/null
```

## Troubleshooting

### 404 Not Found

**Symptom**: Traefik returns 404 when accessing route

**Common Causes**:
1. IngressRoute not applied - check with `kubectl get ingressroute -n traefik`
2. Host mismatch - verify `Host()` matcher in IngressRoute
3. DNS not resolving - check DNS A record points to Traefik LoadBalancer IP

### Certificate Issues

**Symptom**: TLS/SSL errors

**Check**:
```bash
# Verify cert resolver is working
kubectl logs -n traefik -l app.kubernetes.io/name=traefik | grep cert

# Check ACME challenge status
kubectl describe ingressroute <name> -n traefik
```

### Backend Connection Failed

**Symptom**: 502 Bad Gateway or connection errors

**Common Causes**:
1. Backend device unreachable - ping backend IP
2. Wrong port - verify backend device port
3. Self-signed cert issues - ensure `insecureSkipVerify: true` for infrastructure devices

**Check**:
```bash
# Test backend connectivity from cluster
kubectl run -it --rm debug --image=curlimages/curl -- sh
curl -k https://10.10.200.10  # From inside cluster
```

## ServersTransport Configuration

For devices with self-signed certificates (UPS, PDU), we use a custom `ServersTransport`:

```yaml
apiVersion: traefik.io/v1alpha1
kind: ServersTransport
metadata:
  name: insecure-transport
  namespace: traefik
spec:
  insecureSkipVerify: true
```

This tells Traefik to skip TLS verification when connecting to backend devices, while still presenting a valid certificate (from Route53/Let's Encrypt) to end users.

## Related Documentation

- [Traefik Official Docs](https://doc.traefik.io/traefik/)
- [Flux GitOps Overview](../../docs/gitops/flux-overview.md)
- [Making Changes to GitOps Apps](../../docs/gitops/making-changes.md)
- [Traefik IngressRoute CRD](https://doc.traefik.io/traefik/routing/providers/kubernetes-crd/)

## Notes

- **Helm vs Flux**: Traefik **installation** (via Helm) is manual, but IngressRoutes are Flux-managed
- **Certificate Management**: Traefik handles ACME/Let's Encrypt certificates automatically via Route53 DNS-01 challenge
- **LoadBalancer IP**: Traefik gets its external IP from MetalLB (typically first available IP from pool)
- **Namespace**: All IngressRoutes are in the `traefik` namespace, even if routing to services in other namespaces
