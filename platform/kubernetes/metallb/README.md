# MetalLB Load Balancer Configuration

> ⚠️ **MODE = BGP, not Layer 2 (since 2026-05-31; M18/M36).** MetalLB peers with the UDM
> via **eBGP** (`BGPPeer` UDM `10.10.201.1`, ASN 64512) and advertises the VIP /32s via
> `BGPAdvertisement`; the old `L2Advertisement` was **removed**. **Sections below that
> describe Layer-2/ARP mode (and the "L2Advertisement Not Working" troubleshooting) are
> HISTORICAL — they no longer reflect reality.** Consequence: **raw ICMP to a VIP fails by
> design** (the VIP isn't ARP-owned by a node); TCP works. Authoritative detail: the live
> manifest in this directory + `docs/runbooks/archive/bgp-phase-{a,b,c}-*.md`. (UDM BGP is UI-managed
> — no API — so it's durable via the FRR config in git + controller backup.)

MetalLB configuration for bare-metal Kubernetes LoadBalancer services using **BGP mode**
(eBGP peering with the UDM; see the banner above).

**Deployment Method**: This configuration is managed via **Flux GitOps**. Changes are deployed automatically from git commits.

## Overview

MetalLB provides LoadBalancer-type Service support for bare-metal Kubernetes clusters. This configuration defines:

- **IP Address Pool**: 10.10.201.5/32 and 10.10.201.70-10.10.201.90
- **Mode**: **BGP** (eBGP peer = UDM `10.10.201.1` ASN 64512; VIP /32s via `BGPAdvertisement`)
- **Namespace**: `metallb-system` (MetalLB operator installed via Helm separately)

## Architecture

```
┌──────────────────────────────────────┐
│   Kubernetes LoadBalancer Service    │
│   (e.g., Traefik, Technitium DNS)    │
└────────────────┬─────────────────────┘
                 │
                 │ Assigns IP from pool
                 ↓
┌──────────────────────────────────────┐
│   MetalLB controller + speakers      │
│   (IPAddressPool + BGPAdvertisement  │
│    + BGPPeer → UDM, ASN 64512)       │
└────────────────┬─────────────────────┘
                 │
                 │ eBGP — advertises each VIP as a /32
                 ↓
┌──────────────────────────────────────┐
│      UDM router (BGP peer)           │
│   ECMP routes to 10.10.201.5,.70-.90 │
└──────────────────────────────────────┘
```
(Raw ICMP to a VIP fails by design — the VIP is BGP-routed, not ARP-owned by a node. TCP works.)

## IP Allocation

| IP Address / Range | Assignment | Service |
|-------------------|------------|---------|
| 10.10.201.5 | Reserved (VIP) | Technitium DNS |
| 10.10.201.70-10.10.201.90 | Auto-assigned pool | Traefik, other LoadBalancer services |

**Total Available IPs**: 22 (1 reserved + 21 in pool)

## Files

- `metallb-wind.yaml` - IPAddressPool + BGPAdvertisement + BGPPeer configuration
- `kustomization.yaml` - Kustomize configuration for Flux

## Prerequisites

MetalLB operator must be installed separately (typically via Helm):

```bash
helm repo add metallb https://metallb.github.io/metallb
helm install metallb metallb/metallb -n metallb-system --create-namespace
```

This repo only manages the **configuration** (IPAddressPool + BGPAdvertisement + BGPPeer), not the MetalLB installation itself.

## Deployment

### GitOps Deployment (Recommended)

This configuration is managed by Flux. Changes are auto-deployed from git:

```bash
# Edit IP pool configuration
vim platform/kubernetes/metallb/metallb-wind.yaml

# Example: Add more IPs to the pool
addresses:
  - 10.10.201.5/32
  - 10.10.201.70-10.10.201.100  # Expanded range

# Commit and push
git add platform/kubernetes/metallb/metallb-wind.yaml
git commit -m "metallb: expand IP pool to .100"
git push

# Force Flux to sync immediately (no flux CLI on the hosts — CLAUDE.md §3; or wait ~10 min)
kubectl annotate -n flux-system gitrepository/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
kubectl annotate -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite

# Verify
kubectl get ipaddresspool -n metallb-system
kubectl get bgpadvertisement -n metallb-system   # BGP mode — no l2advertisement
kubectl get bgppeer -n metallb-system
```

See [Flux GitOps Overview](../../../docs/setup/gitops/flux-overview.md) for more details.

### Manual Deployment (Not Recommended)

If you need to bypass GitOps (changes will be reverted by Flux):

```bash
kubectl apply -k platform/kubernetes/metallb/
```

## Making Changes

### Add/Remove IP Addresses

```bash
# Edit the IP pool
vim platform/kubernetes/metallb/metallb-wind.yaml

# Modify addresses:
spec:
  addresses:
    - 10.10.201.5/32
    - 10.10.201.70-10.10.201.100  # Expanded

# Commit and push
git add platform/kubernetes/metallb/metallb-wind.yaml
git commit -m "metallb: add more IPs to pool"
git push

# Force reconciliation (no flux CLI on the hosts — CLAUDE.md §3)
kubectl annotate -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
```

### Reserve Specific IP for a Service

To assign a specific IP to a LoadBalancer service:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
  annotations:
    metallb.universe.tf/loadBalancerIPs: 10.10.201.75
spec:
  type: LoadBalancer
  # ...
```

## Verification

### Check IP Pools

```bash
# View configured IP pools
kubectl get ipaddresspool -n metallb-system

# View pool details
kubectl describe ipaddresspool primary -n metallb-system
```

### Check LoadBalancer Services

```bash
# List all LoadBalancer services with assigned IPs
kubectl get svc --all-namespaces -o wide | grep LoadBalancer

# Check MetalLB controller logs
kubectl logs -n metallb-system -l app.kubernetes.io/component=controller -f
```

### Check IP Assignments

```bash
# View which IPs are assigned to which services
kubectl get svc -A --field-selector spec.type=LoadBalancer \
  -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,EXTERNAL-IP:.status.loadBalancer.ingress[0].ip
```

## Troubleshooting

### Service Stuck in `<pending>`

**Symptom**: LoadBalancer service shows `EXTERNAL-IP: <pending>`

**Common Causes**:
1. IP pool exhausted - check available IPs
2. MetalLB controller not running - check pod status
3. IP already assigned elsewhere - check ARP tables

**Check**:
```bash
# Check MetalLB controller
kubectl get pods -n metallb-system

# Check IP pool
kubectl describe ipaddresspool primary -n metallb-system

# Check controller logs
kubectl logs -n metallb-system -l app.kubernetes.io/component=controller
```

### IP Address Conflict

**Symptom**: ARP conflicts or services unreachable

**Solution**: Ensure IP pool doesn't overlap with DHCP range or static IPs used elsewhere on the network.

### BGP session / advertisement not working

**Check**:
```bash
# Verify the BGP peer + advertisement objects exist
kubectl get bgppeer,bgpadvertisement -n metallb-system

# Speaker logs (BGP session establishment / route advertisement)
kubectl logs -n metallb-system -l app.kubernetes.io/component=speaker -f

# On the UDM (UI-managed FRR): confirm the eBGP neighbor is Established and
# the VIP /32s appear as ECMP routes. UDM BGP has no API — it's configured in
# the UI; durable via the FRR config in git + controller backup. See
# docs/runbooks/archive/bgp-phase-{a,b,c}-*.md.
```

## Related Documentation

- [MetalLB Official Docs](https://metallb.universe.tf/)
- [Flux GitOps Overview](../../../docs/setup/gitops/flux-overview.md)
- [Making Changes to GitOps Apps](../../../docs/setup/gitops/making-changes.md)

## Services Using MetalLB

Current LoadBalancer services in the cluster:

- **Traefik**: HTTP/HTTPS ingress (typically gets first available IP from pool)
- **Technitium DNS**: DNS service on 10.10.201.5 (reserved VIP)
- *Others as deployed*

To see current assignments:
```bash
kubectl get svc -A --field-selector spec.type=LoadBalancer
```
