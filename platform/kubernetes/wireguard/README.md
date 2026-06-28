# WireGuard Kubernetes Deployment

## Overview

Primary WireGuard gateway running in Kubernetes with high availability failover to vpn-local VM.

For full architecture documentation, see [docs/architecture/vpn-wireguard.md](../../../docs/architecture/vpn-wireguard.md).

## Components

| File | Purpose |
|------|---------|
| `00-namespace.yaml` | Namespace with privileged pod security |
| `01-secrets.sops.yaml` | WireGuard keys (SOPS-encrypted) |
| `02-configmap.yaml` | Documentation/reference config |
| `03-deployment.yaml` | WireGuard + Keepalived deployment |
| `04-cleanup-daemonset.yaml` | Orphaned interface cleanup |
| `kustomization.yaml` | Kustomize configuration |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    wireguard namespace                       │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Deployment: wireguard (replicas: 1)                        │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Pod (hostNetwork: true, any worker, no cp)        │    │
│  │  ┌─────────────────┐  ┌─────────────────┐           │    │
│  │  │   wireguard     │  │   keepalived    │           │    │
│  │  │   container     │  │   sidecar       │           │    │
│  │  │                 │  │                 │           │    │
│  │  │ - wg0 (s2s)     │  │  - VIP mgmt     │           │    │
│  │  │   Port 9820     │  │  - VRRP pri 150 │           │    │
│  │  │ - wg1 (remote)  │  │  - Health check │           │    │
│  │  │   Port 9821     │  │                 │           │    │
│  │  └─────────────────┘  └─────────────────┘           │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                             │
│  DaemonSet: wireguard-cleanup (on all workers)              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Removes orphaned wg0/VIP when pod moves nodes      │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## Deployment

### Via Flux (automatic)

Changes pushed to `main` are automatically deployed by Flux.

```bash
# Force reconciliation (no flux CLI on the hosts — CLAUDE.md §3)
kubectl annotate -n flux-system gitrepository/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
kubectl annotate -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
```

### Manual

```bash
kubectl apply -k platform/kubernetes/wireguard/
```

## Configuration

### Key Settings

| Setting | Value | Notes |
|---------|-------|-------|
| hostNetwork | true | Direct host networking for tunnel |
| Node affinity | Any worker, control-plane excluded | `required` rule excludes control-plane only (no per-node preference) |
| tolerationSeconds | 10 | Fast eviction on node failure |
| VRRP priority | 150 | Higher than vpn-local (100) |
| VIP | 10.10.201.20 | Floating between K8s and vpn-local |

> **VRRP failover correctness fix (commit b4999c9):** the keepalived
> sidecar now releases the VIP cleanly on pod termination (preStop hook
> + `garp_master_refresh`), so vpn-local takes over within VRRP's
> advert-interval instead of waiting for the gratuitous-ARP cache to
> age out. If you're debugging a stuck VIP, that commit is the
> reference.

### Probes

| Probe | Target | Initial Delay | Period | Failure Threshold |
|-------|--------|---------------|--------|-------------------|
| Startup | `which wg && ip link show wg0` | 30s | 10s | 30 (≈5 min for apt-get install) |
| Liveness | `ip link show wg0 && ip link show wg1` | — | 10s | 3 |
| Readiness | `wg show wg0 && wg show wg1` | — | 10s | 3 |

## Operations

### Check Status

```bash
# Pod status
kubectl get pods -n wireguard

# Tunnel status
kubectl exec -n wireguard deployment/wireguard -c wireguard -- wg show wg0

# VIP status
kubectl exec -n wireguard deployment/wireguard -c keepalived -- ip addr show | grep 10.10.201.20

# Cleanup daemon logs
kubectl logs -n wireguard daemonset/wireguard-cleanup
```

### Test Failover

```bash
# Scale down (vpn-local will take over)
kubectl scale deployment wireguard -n wireguard --replicas=0

# Verify vpn-local has VIP
ansible vpn-local -m shell -a "ip addr show | grep 10.10.201.20"

# Scale back up
kubectl scale deployment wireguard -n wireguard --replicas=1
```

### Restart

```bash
kubectl rollout restart deployment wireguard -n wireguard
```

## Secrets Management

Secrets are SOPS-encrypted with age. To edit:

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
sops platform/kubernetes/wireguard/01-secrets.sops.yaml
```

**Important:** K8s and vpn-local must use the SAME keys so AWS sees a single peer.

## Troubleshooting

### Pod won't start

1. Check for orphaned wg0 on the node:
   ```bash
   kubectl logs -n wireguard daemonset/wireguard-cleanup
   ```

2. Check probe failures:
   ```bash
   kubectl describe pod -n wireguard -l app=wireguard
   ```

### VIP not assigned

1. Check keepalived logs:
   ```bash
   kubectl logs -n wireguard deployment/wireguard -c keepalived
   ```

2. Check VRRP communication:
   ```bash
   # Should see VRRP packets
   kubectl exec -n wireguard deployment/wireguard -c keepalived -- tcpdump -i eth0 vrrp
   ```

### Tunnel not working

1. Verify handshake:
   ```bash
   kubectl exec -n wireguard deployment/wireguard -c wireguard -- wg show wg0
   # latest handshake should be recent
   ```

2. Check connectivity:
   ```bash
   kubectl exec -n wireguard deployment/wireguard -c wireguard -- ping -c 3 10.255.255.1
   ```

## Files

### 03-deployment.yaml Key Sections

- **wireguard container**: Installs wireguard-tools, creates wg0.conf, runs wg-quick
- **keepalived sidecar**: Manages VIP 10.10.201.20 via VRRP
- **preStop hooks**: Clean up wg0 and VIP on termination
- **tolerations**: Fast eviction (10s) on node failure

### 04-cleanup-daemonset.yaml

- Runs on all worker nodes
- Queries K8s API to check if wireguard pod is on this node
- Removes orphaned wg0 interface and VIP if pod is not present
- Uses `KUBERNETES_SERVICE_HOST` env var (hostNetwork can't resolve DNS)
