# Network Notes

## Layers (simplified)
- Underlay: your VLANs/subnets routed by your L3 switch/router
- Node IPs: kubelet, API server, etc.
- CNI Pod network: pod-to-pod networking inside the cluster (Cilium/Calico/etc.)
- Service network: ClusterIP services inside cluster
- Ingress/LB: north-south traffic into cluster (MetalLB + Traefik)

## Current pattern
- Nodes live on VLAN 201
- MetalLB allocates a VIP (e.g., Traefik at 10.10.201.70)
- DNS points `*.wind.etherport.net` → MetalLB VIP
