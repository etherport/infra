# Network Architecture

Overview of the network topology and VLAN structure for the homelab.

## Network Layers

| Layer | Description |
|-------|-------------|
| Underlay | VLANs/subnets routed by L3 switch/router |
| Node IPs | Kubelet, API server, etc. |
| CNI Pod network | Pod-to-pod networking inside the cluster (Cilium/Calico/etc.) |
| Service network | ClusterIP services inside cluster |
| Ingress/LB | North-south traffic into cluster (MetalLB + Traefik) |

## Current Configuration

| Component | Configuration |
|-----------|---------------|
| Node VLAN | 201 (10.10.201.0/24) |
| LoadBalancer | MetalLB (VIP example: Traefik at 10.10.201.70) |
| DNS | `*.wind.etherport.net` resolves to MetalLB VIP |

## Traffic Flow

```
External Request
      |
      v
  DNS (Route53)
      |
      v
  MetalLB VIP (10.10.201.70)
      |
      v
  Traefik Ingress
      |
      v
  Kubernetes Service
      |
      v
  Application Pod
```

## Related Documentation

- [Architecture Overview](overview.md)
- [Firewall Zones](firewall-zones.md)
- [VPN Infrastructure](vpn-wireguard.md)
