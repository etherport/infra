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
| Default | Ceph-backed PVCs for persistent apps (Traefik, Grafana, etc.). Ceph mon at `10.10.210.41:6789` (and `:3300` msgr2) on VLAN 210 (dedicated storage network); see [`docs/runbooks/archive/ceph-vlan-migration.md`](../runbooks/archive/ceph-vlan-migration.md). |
| Legacy | NFS tests retained only under `platform/kubernetes/tests/` |

## Appliances (non-K8s)

| Component | IP | Notes |
|-----------|----|----|
| UDM Pro | 10.10.200.1 | UniFi gateway + controller; config in `infra/terraform/unifi/` + UDM-side ansible. Probed via blackbox-exporter. |
| Protect | 10.10.212.10 | Camera NVR. Probed via blackbox-exporter. |
| UNAS Pro | 10.10.209.10 | NAS appliance (UniFi). Probed via blackbox-exporter. |
| USW-Pro-Max-48-PoE + USW-Aggregation | n/a | Switches managed via UniFi controller; see [reference/node-vlan-setup.md](../reference/node-vlan-setup.md) for LAG quirks. |

## Edge / public access

| Component | Notes |
|---|---|
| Traefik | LoadBalancer on 10.10.201.70; serves `*.wind.etherport.net` via cert-manager wildcard + TLSStore default |
| AWS ALB | Public `*.wind.etherport.net` reverse-proxy through VPN; planned drop after Cloudflare migration |
| Cloudflare Tunnel | `cloudflared` deploy (`platform/kubernetes/cloudflared/`) outbound-only; routes `approve.etherport.net` through CF Access (Google SSO). Used for AI advisor approve URL. Full-zone migration scaffold lives in `infra/terraform/cloudflare/`; NS-cutover at registrar pending. |
| Tailscale | Per-service ingresses managed by the Tailscale operator (e.g. `remediation-approve.<tailnet>.ts.net`) for tailnet-only access |

## Cluster automation (auto-remediation namespace)

- Static rule-based remediation (`platform/kubernetes/auto-remediation/configmap.yaml`) — 22 rules.
- AI advisor (Phases 1/2/3 all live) — 18 action types across 3 tiers including SSH-based host actions. Closed-loop verification + cross-session memory + deep-mode tool-use. See [`README.md`](../../README.md#ai-alert-advisor-auto-remediation-namespace) at repo root for architecture summary; per-phase runbooks under [`docs/runbooks/ai-advisor-phase*`](../runbooks/).

## Related Documentation

- [Network Architecture](network.md)
- [Firewall Zones](firewall-zones.md)
- [VPN Infrastructure](vpn-wireguard.md)
- [AWS Infrastructure](aws-infrastructure.md)
