# Plex Media Server - Kubernetes Deployment

GPU-accelerated Plex Media Server deployment with hardware transcoding on Tesla P40.

**Deployment Method**: This application is managed via **Flux GitOps**. Changes are deployed automatically from git commits.

## Overview

- **Namespace**: `plex`
- **Storage**: 25GB Ceph RBD for config/metadata
- **Media Access**: NFS mounts from `sequoia.wind.etherport.net`
- **GPU**: NVIDIA Tesla P40 with time-slicing (hardware transcoding)
- **Access**: https://plex.wind.etherport.net
- **GitOps**: Managed by Flux (see [Flux Overview](../../docs/gitops/flux-overview.md))

## Architecture

```
┌─────────────────────────────────────────────────┐
│                   Users                         │
│         https://plex.wind.etherport.net         │
└────────────────────┬────────────────────────────┘
                     │
            ┌────────▼────────┐
            │  Traefik Ingress │
            │  (port 80/443)   │
            └────────┬────────┘
                     │
            ┌────────▼────────┐
            │  Plex Service    │
            │  (ClusterIP      │
            │   port 32400)    │
            └────────┬────────┘
                     │
        ┌────────────▼──────────────┐
        │    Plex Pod (k8s-gpu1)    │
        │                           │
        │  ┌─────────────────────┐  │
        │  │  Plex Container     │  │
        │  │  + GPU (Tesla P40)  │  │
        │  └─────────────────────┘  │
        │                           │
        │  Volumes:                 │
        │  • /config (Ceph 25GB)    │
        │  • /media/movies (NFS)    │
        │  • /media/tv (NFS)        │
        │  • /transcode (tmpfs)     │
        └───────────────────────────┘
```

## Prerequisites

- GPU worker node (k8s-gpu1) with NVIDIA GPU Operator
- Ceph RBD storage class available
- NFS server with media libraries
- DNS: `plex.wind.etherport.net` → Traefik LoadBalancer IP

## Deployment

### GitOps Deployment (Recommended)

This application is managed by Flux. Changes are auto-deployed from git:

```bash
# Edit any configuration (e.g., change image version, resources, etc.)
vim platform/kubernetes/plex/02-deployment.yaml

# Commit and push
git add platform/kubernetes/plex/02-deployment.yaml
git commit -m "plex: update configuration"
git push

# Force Flux to sync immediately (or wait ~10 minutes)
flux reconcile source git flux-system
flux reconcile kustomization flux-system

# Verify deployment
kubectl get pods -n plex
kubectl logs -n plex -l app=plex -f
```

See [Making Changes to GitOps Apps](../../docs/gitops/making-changes.md) for detailed workflows.

### Manual Deployment (Not Recommended)

If you need to bypass GitOps (changes will be reverted by Flux):

```bash
kubectl apply -k platform/kubernetes/plex/

# Or deploy individual files:
kubectl apply -f 00-namespace.yaml
kubectl apply -f 01-pvc-config.yaml
kubectl apply -f 02-deployment.yaml
kubectl apply -f 03-service.yaml
kubectl apply -f 04-ingress.yaml
```

Or apply all at once:
```bash
kubectl apply -f .
```

### 2. Get Claim Token (First-Time Setup)

For initial Plex setup, get a claim token:

1. Visit: https://www.plex.tv/claim/
2. Copy the claim token (valid for 4 minutes)
3. Uncomment and update in `02-deployment.yaml`:
   ```yaml
   - name: PLEX_CLAIM
     value: "claim-XXXXXXXXXXXXXXXXXXXX"
   ```
4. Reapply: `kubectl apply -f 02-deployment.yaml`
5. After setup completes, remove the claim token and reapply

### 3. Verify Deployment

```bash
# Check pod status
kubectl get pods -n plex

# Check GPU allocation
kubectl get pod -n plex -o yaml | grep nvidia.com/gpu.shared

# Check logs
kubectl logs -n plex -l app=plex --tail=50

# Verify GPU is recognized
kubectl exec -n plex -it deployment/plex -- nvidia-smi
```

### 4. Access Plex

Navigate to: **https://plex.wind.etherport.net**

Sign in with: **grahamsm@gmail.com** (username: grah251)

## Configuration

### GPU Hardware Transcoding

Plex is configured with NVIDIA GPU access for hardware transcoding:

1. Navigate to **Settings** → **Transcoder**
2. Enable: **Use hardware acceleration when available**
3. Select: **NVIDIA NVENC**
4. Save changes

The Tesla P40 supports:
- H.264 (AVC) encoding/decoding
- HEVC (H.265) encoding/decoding
- Up to 4K resolution
- Multiple simultaneous transcodes (time-sliced GPU)

### Network Configuration (Critical for 4K Playback)

**Configure LAN Networks** to ensure high-quality playback without transcoding:

1. Navigate to **Settings** → **Network**
2. Under **LAN Networks**, add the following networks:
   ```
   10.42.0.0/16,10.43.0.0/16
   ```
   - `10.42.0.0/16` - Cilium pod network
   - `10.43.0.0/16` - Kubernetes service network
3. Save changes

**Why this matters**: Without these networks configured, Plex treats connections from the ingress as "remote" and limits streaming quality. Adding these networks ensures Plex recognizes traffic as local and allows Original/Maximum quality streaming including 4K.

### Media Libraries

Configure libraries in Plex:

| Library | Path | Content |
|---------|------|---------|
| Movies | `/media/movies` | Movie collection |
| TV Shows | `/media/tv` | TV series |

Add libraries:
1. **Settings** → **Libraries** → **Add Library**
2. Choose type (Movies/TV Shows)
3. Select folder path from table above
4. **Add Library**

### Resource Limits

Current resource allocation:

| Resource | Request | Limit |
|----------|---------|-------|
| CPU | 1 core | 4 cores |
| Memory | 2GB | 8GB |
| GPU | 1 slice | 1 slice |
| Transcode (tmpfs) | - | 4GB |

Adjust in `02-deployment.yaml` if needed.

## Storage

### Persistent Config (25GB Ceph RBD)

Stores:
- Plex configuration
- Library metadata and thumbnails
- Watch history and preferences
- User accounts

**Location**: `/config` (PVC: `plex-config`)

### Media Libraries (NFS - Read-only)

| Share | NFS Path | Mount Point |
|-------|----------|-------------|
| Movies | `sequoia.wind.etherport.net:/var/nfs/shared/Media/Movies` | `/media/movies` |
| TV Shows | `sequoia.wind.etherport.net:/var/nfs/shared/Media/TV Shows` | `/media/tv` |

### Transcode Storage (4GB tmpfs)

Fast in-memory storage for active transcoding sessions. Automatically cleared on pod restart.

## Remote Access

Plex is configured for remote access via `https://plex.wind.etherport.net`.

### Configuration Requirements

**1. Environment Variables (02-deployment.yaml)**
```yaml
- name: ADVERTISE_IP
  value: "https://plex.wind.etherport.net:443/"
```

**2. Ingress Configuration (04-ingress.yaml)**
- Uses Traefik IngressRoute with TLS (Let's Encrypt)
- Middleware for proper headers (X-Forwarded-Proto)
- Buffering middleware for large requests

**3. WAF Configuration (CRITICAL for Transcoding)**

If using AWS ALB with WAF, Plex transcode URLs can exceed the default query string size limit (2048 bytes) and will return **403 Forbidden** errors when playing content.

**Fix:** Add a WAF rule to allow Plex before the size restriction rules:

In AWS WAF Web ACL (`CreatedByALB-private-infra-alb`):

1. Go to **Rules** → **Add rules** → **Add my own rules and rule groups**
2. Rule type: **Rule builder**
3. Name: `AllowPlexLongURLs`
4. Type: **Regular rule**
5. If a request: **matches the statement**
6. Statement:
   - Inspect: **Header**
   - Header field name: `host`
   - Match type: **Exactly matches string**
   - String to match: `plex.wind.etherport.net`
   - Text transformation: **Lowercase**
7. Action: **Allow**
8. Priority: **0** (must be first, before managed rule groups)

This bypasses the `SizeRestrictions_QUERYSTRING` rule from `AWSManagedRulesCommonRuleSet` for Plex.

**Note:** Changes may take 1-2 minutes to propagate.

### Verification

1. **Settings → Remote Access** in Plex should show:
   - Status: "Fully accessible outside your network"
   - Public port: 443

2. Test remote playback with transcoding:
   - Access Plex from outside your network (mobile data)
   - Play content that requires transcoding (different quality/format)
   - Should play without 403 errors

### Troubleshooting Remote Access

**"Device is not responding"**
- Check Plex is publishing to plex.tv: `PublishServerOnPlexOnlineKey="1"`
- Verify custom connections: `customConnections="https://plex.wind.etherport.net:443/"`
- Restart Plex pod: `kubectl rollout restart deployment/plex -n plex`

**403 Errors When Playing Content**
- Verify WAF rule is active and priority 0
- Check WAF logs in CloudWatch for blocked requests
- Temporarily disable managed rules to confirm WAF is the issue

**Intermittent Connectivity**
- Enable Relay in Plex Settings → Network
- Relay acts as fallback when direct connection fails

## Troubleshooting

### Pod Won't Start

Check GPU node availability:
```bash
kubectl get nodes -l gpu=true
kubectl describe node k8s-gpu1
```

Check PVC binding:
```bash
kubectl get pvc -n plex
```

### No GPU Detected

Verify GPU operator is running:
```bash
kubectl get pods -n gpu-operator-system
```

Verify GPU resources on node:
```bash
kubectl get node k8s-gpu1 -o json | jq '.status.capacity."nvidia.com/gpu.shared"'
```

### NFS Mount Failures

Test NFS connectivity from pod:
```bash
kubectl exec -n plex -it deployment/plex -- mount | grep nfs
kubectl exec -n plex -it deployment/plex -- ls -la /media/movies
kubectl exec -n plex -it deployment/plex -- ls -la /media/tv
```

Test from host:
```bash
showmount -e sequoia.wind.etherport.net
```

### Transcoding Not Using GPU

1. Check hardware acceleration is enabled in Plex settings
2. Verify GPU is accessible in container:
   ```bash
   kubectl exec -n plex -it deployment/plex -- nvidia-smi
   ```
3. Check Plex logs for transcoding errors:
   ```bash
   kubectl logs -n plex -l app=plex | grep -i transcode
   ```

### Ingress Not Working

Check Traefik ingress:
```bash
kubectl get ingress -n plex
kubectl describe ingress -n plex plex
```

Verify DNS:
```bash
nslookup plex.wind.etherport.net
```

## Maintenance

### Update Plex Version

The deployment uses `plexinc/pms-docker:latest`. To update:

```bash
kubectl rollout restart deployment/plex -n plex
```

Or pin to specific version in `02-deployment.yaml`:
```yaml
image: plexinc/pms-docker:1.40.0.7998-c29d4c0c8
```

### Backup Configuration

Plex config is stored in Ceph RBD PVC. To backup:

```bash
kubectl exec -n plex deployment/plex -- tar czf - /config | \
  cat > plex-config-backup-$(date +%Y%m%d).tar.gz
```

### Restore from Previous Install

To restore from previous Plex Media Server directory:

1. Stop Plex pod: `kubectl scale deployment/plex -n plex --replicas=0`
2. Copy backup to PVC:
   ```bash
   kubectl cp <backup-dir> plex/<pod-name>:/config/
   ```
3. Restart: `kubectl scale deployment/plex -n plex --replicas=1`

**Note**: Update library paths in Plex settings after restore to match new NFS mount points.

## Monitoring

### Check GPU Utilization

View DCGM metrics in Grafana:
- Dashboard: **NVIDIA DCGM Exporter**
- Metrics: GPU utilization, temperature, memory usage, encoder/decoder sessions

### View Logs

```bash
# Real-time logs
kubectl logs -n plex -l app=plex --follow

# Last 100 lines
kubectl logs -n plex -l app=plex --tail=100
```

### Resource Usage

```bash
kubectl top pod -n plex
```

## Security Considerations

- NFS volumes mounted **read-only** to prevent accidental media deletion
- Plex runs as UID/GID 1000 (configurable)
- No external ports exposed (access via Traefik ingress only)
- HTTPS enforced via Traefik middleware

## Related Documentation

- [NVIDIA GPU Operator Setup](../gpu-operator/values.yaml)
- [GPU Worker Node Configuration](../../../infra/terraform/proxmox/k8s-vms/main.tf)
- [Production Readiness Checklist](../../../docs/PRODUCTION-READINESS-CHECKLIST.md)

---

**Created**: 2025-12-31
**Maintainer**: Graham Smith (grahamsm@gmail.com)
