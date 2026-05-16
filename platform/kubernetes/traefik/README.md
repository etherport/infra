# Traefik IngressRoute Configurations

Custom IngressRoute configurations for Traefik reverse proxy.

**Deployment Method**: These configurations are managed via **Flux GitOps**. Changes are deployed automatically from git commits.

## Overview

This directory contains IngressRoute configurations for services that need custom routing beyond standard Ingress resources. The Traefik controller itself is installed via Helm (not managed by Flux), but these IngressRoutes **are** Flux-managed.

- **Traefik Installation**: Flux HelmRelease at
  `clusters/wind/helm-releases/traefik.yaml` (values in `traefik-values.yaml`);
  HA with `replicas: 2`, no ACME PVC.
- **TLS / Certificates**: cert-manager wildcard `*.wind.etherport.net`
  (DNS-01 via Route53) + Traefik default `TLSStore`. All IngressRoutes
  automatically pick up the wildcard — no per-route `certResolver` needed.
- **IngressRoute Configuration**: Managed via Flux GitOps (this directory)
- **Namespace**: `traefik`

## Files

| File | Purpose |
|------|---------|
| `ingressroute-infrastructure.yaml` | IngressRoutes for UPS and PDU web UIs with self-signed cert bypass |
| `ingressroute-proxmox.yaml` | IngressRoute for Proxmox VE web UI (HTTPS passthrough) |
| `clusterissuer-letsencrypt.yaml` | cert-manager ClusterIssuer (DNS-01 via Route53) |
| `certificate-wildcard.yaml` | Wildcard certificate `*.wind.etherport.net` |
| `tlsstore-default.yaml` | Traefik default TLSStore that serves the wildcard for every IngressRoute |
| `route53-credentials.sops.yaml` | SOPS-encrypted AWS creds used by cert-manager DNS-01 |
| `kustomization.yaml` | Kustomize configuration for Flux |
| `traefik-values.yaml` | Helm values for Traefik (HelmRelease defined in `clusters/wind/helm-releases/traefik.yaml`) |
| `pvc-traefik-ceph.yaml` | **Legacy.** Was the ACME PVC; no longer referenced by the kustomization. Safe to remove once confirmed unbound. |
| `traefik-acme-fix.yaml` | **Legacy.** Workaround for embedded-ACME issues; cert-manager replaces it. |

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
         │ HTTPS (wildcard cert from cert-manager + TLSStore default)
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

Traefik is installed via a Flux HelmRelease (since 2026-05-12):

- `clusters/wind/helm-releases/traefik.yaml` — the HelmRelease itself
- `platform/kubernetes/traefik/traefik-values.yaml` — Helm values (HA
  `replicas: 2`, no ACME / no PVC, TLS served from cert-manager wildcard)

To force a re-install/upgrade, reconcile the HelmRelease via Flux:

```bash
flux reconcile helmrelease traefik -n flux-system
```

The legacy "helm install" path is no longer used.

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
  tls: {}   # Wildcard from TLSStore default — no certResolver needed

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

- **Flux-managed**: Both the Traefik install (HelmRelease) and the
  IngressRoutes/cert-manager objects in this directory are Flux-managed.
- **Certificate Management**: cert-manager issues a wildcard
  `*.wind.etherport.net` certificate via Route53 DNS-01
  (`clusterissuer-letsencrypt.yaml` + `certificate-wildcard.yaml`), and
  the Traefik default `TLSStore` (`tlsstore-default.yaml`) serves it for
  every IngressRoute. Individual routes no longer need a `certResolver`.
- **LoadBalancer IP**: Traefik gets its external IP from MetalLB (typically first available IP from pool)
- **Namespace**: All IngressRoutes are in the `traefik` namespace, even if routing to services in other namespaces
