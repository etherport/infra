# Architecture Overview

High-level infrastructure design for the homelab environment.

## Physical / Virtual Infrastructure

| Component | Details |
|-----------|---------|
| Hypervisor | Proxmox (`pve.wind.etherport.net`) |
| Kubernetes | 3 CP HA (.50-.52) + 4 workers (.53-.56) + 1 GPU (.60) |

### Kubernetes Nodes

| Node | IP Address | Role |
|------|------------|------|
| k8s-cp1 | 10.10.201.50 | Control Plane (HA) |
| k8s-cp2 | 10.10.201.51 | Control Plane (HA) |
| k8s-cp3 | 10.10.201.52 | Control Plane (HA) |
| k8s-w1 | 10.10.201.53 | Worker |
| k8s-w2 | 10.10.201.54 | Worker |
| k8s-w3 | 10.10.201.55 | Worker |
| k8s-w4 | 10.10.201.56 | Worker |
| k8s-gpu1 | 10.10.201.60 | GPU Worker (NVIDIA Tesla P40) |

## Networking

| Component | Configuration |
|-----------|---------------|
| Node network (primary) | VLAN 201 (10.10.201.0/24) — kubelet, API, pod-network underlay |
| Storage network | VLAN 210 (10.10.210.0/24) — dedicated Ceph traffic; each K8s node has `enp6s22` at MTU 9000 (10.10.210.50-60) reaching the PVE Ceph mon at 10.10.210.41. Migrated 2026-05-18. |
| LoadBalancer VIPs | MetalLB: 10.10.201.70-90 |
| Ingress | Traefik (LoadBalancer IP); TLS via cert-manager wildcard `*.wind.etherport.net` + TLSStore default (see `platform/kubernetes/traefik/clusterissuer-letsencrypt.yaml`, `certificate-wildcard.yaml`, `tlsstore-default.yaml`) |

## Storage

| Type | Description |
|------|-------------|
| Default | Ceph-backed PVCs for persistent apps (Traefik, Grafana, etc.). Ceph mon at `10.10.210.41:6789` on VLAN 210 (dedicated storage network); see [`docs/runbooks/ceph-vlan-migration.md`](runbooks/ceph-vlan-migration.md). |
| Legacy | NFS tests retained only under `platform/kubernetes/tests/` |

## Related Documentation

- [Network Architecture](network.md)
- [Firewall Zones](firewall-zones.md)
- [VPN Infrastructure](vpn-wireguard.md)
- [AWS Infrastructure](aws-infrastructure.md)
