# Architecture Overview

## Physical / Virtual
- Hypervisor: Proxmox (`pve.wind.etherport.net`)
- Kubernetes VMs: 1 control-plane + 2 workers
  - k8s-cp1: 10.10.201.50
  - k8s-w1:  10.10.201.51
  - k8s-w2:  10.10.201.52

## Networking (high level)
- Node network: VLAN 201 (10.10.201.0/24)
- L4 LoadBalancer VIPs (MetalLB): 10.10.201.70-90 (example)
- Ingress: Traefik (LoadBalancer IP, DNS-01 Route53)

## Storage (current)
- Default goal: Ceph-backed PVCs for persistent apps (Traefik, Grafana, etc.)
- Legacy: NFS tests retained only under `platform/kubernetes/tests/`
