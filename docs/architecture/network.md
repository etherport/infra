# Network Architecture

Overview of the network topology and VLAN structure for the homelab.

## Network Layers

| Layer | Description |
|-------|-------------|
| Underlay | VLANs/subnets routed by L3 switch/router |
| Node IPs | Kubelet, API server, etc. |
| CNI Pod network | Pod-to-pod networking inside the cluster (Cilium) |
| Service network | ClusterIP services inside cluster |
| Ingress/LB | North-south traffic into cluster (MetalLB + Traefik) |

## Current Configuration

| Component | Configuration |
|-----------|---------------|
| Node VLAN (primary) | 201 (10.10.201.0/24) — kubelet, API, pod-network underlay |
| Storage VLAN | 210 (10.10.210.0/24) — dedicated Ceph network, added 2026-05-18. PVE mon on 10.10.210.41; K8s nodes on .50-.60 via `enp6s22` (MTU 9000). See [`docs/runbooks/archive/ceph-vlan-migration.md`](../runbooks/archive/ceph-vlan-migration.md). |
| Multus VLAN parents | 202 (client), 204 (IoT), 205 (security) — `enp6s19/20/21` on every K8s node, baked in via netplan. Per-pod IPs via NADs in `platform/kubernetes/multus/`. See [`docs/reference/node-vlan-setup.md`](../reference/node-vlan-setup.md). |
| Proxmox SDN | Named bridges per VLAN on PVE: `servers` (201), `clients` (202), `iot` (204), `security` (205), `vsan` (209), `guest` (206), `unifi` (212). Standalone VMs migrated 2026-05-18; K8s VM NICs 1-4 migrated to SDN bridges 2026-05-22 (PR 5). NIC 5 (Ceph) stays on `vmbr0+vlan_id=210` to avoid conflict with PVE's own `vmbr0.210`. See [`infra/terraform/proxmox/sdn/`](../../infra/terraform/proxmox/sdn/). |
| LoadBalancer | MetalLB (VIP example: Traefik at 10.10.201.70) |
| DNS | `*.wind.etherport.net` resolves to MetalLB VIP |

## Traffic Flow

```
External Request
      |
      v
  DNS (Cloudflare — authoritative for etherport.net since 2026-05; Route53 deleted 2026-05-27)
      |
      v
  Cloudflare Tunnel (cloudflared) + CF Access   [*.wind.etherport.net]
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

The public edge is the Cloudflare Tunnel + Access (ALB decommissioned
2026-05-27; the old WireGuard-fronted ALB tier no longer exists). See
`docs/runbooks/archive/cloudflare-access-enable.md`.

**MetalLB is BGP-only** (eBGP to the UDM at `10.10.201.1`), not L2 —
VIPs (Traefik `.70`, DNS `.5` + per-pod `.71`/`.72`, syslog `.73`, tailscale
static-endpoint `.74`) are advertised via BGP, so raw ICMP to a VIP fails by
design and a same-subnet VLAN-201 host can't reach them. `.6` is **not** a
MetalLB VIP — it's the separate `vpn-fallback` VM's Technitium instance (a
normal L2-reachable host on Servers/201), kept as DNS secondary precisely
because it doesn't share the BGP-VIP reachability gap.

## Related Documentation

- [Architecture Overview](overview.md)
- [Firewall Zones](firewall-zones.md)
- [VPN Infrastructure](vpn-wireguard.md)
- [VPN: Tailscale](vpn-tailscale.md)
