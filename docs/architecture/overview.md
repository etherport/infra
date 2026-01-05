# Architecture Overview

High-level infrastructure design for the homelab environment.

## Physical / Virtual Infrastructure

| Component | Details |
|-----------|---------|
| Hypervisor | Proxmox (`pve.wind.etherport.net`) |
| Kubernetes | 1 control-plane + 4 workers |

### Kubernetes Nodes

| Node | IP Address | Role |
|------|------------|------|
| k8s-cp1 | 10.10.201.50 | Control Plane |
| k8s-w1 | 10.10.201.51 | Worker |
| k8s-w2 | 10.10.201.52 | Worker |
| k8s-w3 | 10.10.201.53 | Worker |
| k8s-gpu1 | 10.10.201.54 | GPU Worker (NVIDIA Tesla P40) |

## Networking

| Component | Configuration |
|-----------|---------------|
| Node network | VLAN 201 (10.10.201.0/24) |
| LoadBalancer VIPs | MetalLB: 10.10.201.70-90 |
| Ingress | Traefik (LoadBalancer IP, DNS-01 Route53) |

## Storage

| Type | Description |
|------|-------------|
| Default | Ceph-backed PVCs for persistent apps (Traefik, Grafana, etc.) |
| Legacy | NFS tests retained only under `platform/kubernetes/tests/` |

## Related Documentation

- [Network Architecture](network.md)
- [Firewall Zones](firewall-zones.md)
- [VPN Infrastructure](vpn-wireguard.md)
- [AWS Infrastructure](aws-infrastructure.md)
