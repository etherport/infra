# WireGuard VPN Infrastructure

## Overview

Site-to-site VPN connecting local homelab to AWS.

> **⚠️ ALB decommissioned 2026-05-27.** This tunnel previously fronted the AWS ALB public-ingress path; the public edge is now the CF Tunnel + Access (no ALB). The site-to-site tunnel remains in use for AWS↔homelab connectivity (e.g. dns-aws, regional travel VPNs).

**Note:** For remote client access, [Tailscale](vpn-tailscale.md) is the primary solution.

> **BACKUP:** WireGuard wg1 (remote access) is retained as a backup for restrictive networks where Tailscale's DERP relay performance is insufficient. See [When to Use WireGuard vs Tailscale](#when-to-use-wireguard-vs-tailscale) below.

## High Availability Architecture

The local site WireGuard gateway runs in high availability mode with automatic failover:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    WireGuard HA Topology (Site-to-Site)                         │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│   AWS (us-west-2)                        Local Homelab                          │
│   ┌─────────────────┐                    ┌─────────────────────────────────┐    │
│   │    vpn-aws      │                    │         Floating VIP            │    │
│   │  44.240.60.80   │◄───── wg0 ────────►│        10.10.201.20             │    │
│   │  10.10.100.10   │    (site-to-site)  │                                 │    │
│   │                 │                    │   ┌───────────────────────────┐ │    │
│   │  wg0: S2S       │                    │   │  K8s WireGuard Pod        │ │    │
│   │  wg1: Remote    │                    │   │  (PRIMARY - priority 150) │ │    │
│   └────────┬────────┘                    │   │  On any worker node       │ │    │
│            │                             │   └─────────────┬─────────────┘ │    │
│            │                             │                 │ VRRP          │    │
│            │                             │   ┌─────────────▼─────────────┐ │    │
│            │                             │   │  vpn-local VM             │ │    │
│   wg1 (remote access)                    │   │  (BACKUP - priority 100)  │ │    │
│   10.254.0.0/24                          │   │  10.10.201.15             │ │    │
│   [BACKUP for slow DERP]                 │   │  wg0 starts on failover   │ │    │
│            │                             │   └───────────────────────────┘ │    │
│            ▼                             └─────────────────────────────────┘    │
│   Remote clients                                                                │
│   (Graham: 10.254.0.10)                                                         │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Failover Behavior

| Component | Primary | Backup | Failover Time |
|-----------|---------|--------|---------------|
| WireGuard wg0 | K8s pod | vpn-local VM | ~10-15 seconds |
| VIP 10.10.201.20 | K8s node (k8s-w1) | vpn-local VM | ~2-3 seconds |

**How it works:**
1. K8s WireGuard pod runs with Keepalived sidecar (VRRP priority 150)
2. vpn-local VM runs Keepalived (VRRP priority 100, `nopreempt`)
3. VIP 10.10.201.20 floats between them via VRRP
4. When K8s pod fails, vpn-local acquires VIP and starts wg0
5. When K8s pod recovers, it reclaims VIP; vpn-local stops wg0

**Cleanup DaemonSet:**
A cleanup daemon runs on all worker nodes to remove orphaned wg0 interfaces when the WireGuard pod moves between nodes.

## Network Addressing

| Network | CIDR | Purpose |
|---------|------|---------|
| 10.255.255.0/29 | Site-to-site tunnel | Multi-endpoint tunnel (vpn-aws=.1, homelab=.2, regional=.3-.6) |
| 10.254.0.0/24 | Remote access | Mobile/roaming client VPN |
| 10.10.192.0/19 | Local homelab | All local VLANs (10.10.192.0 - 10.10.223.255) |
| 10.10.100.0/22 | AWS networks | AWS VPC and related (10.10.100.0 - 10.10.103.255) |

## Regional Travel VPNs

**TEMPORARY INFRASTRUCTURE** - Regional VPNs are deployed for travel and destroyed when not needed.

### Current Deployment

| Region | IP Assignment | VPC CIDR | Status | Notes |
|--------|---------------|----------|--------|-------|
| ap-south-1 (Mumbai) | 10.255.255.3 | 10.10.112.0/24 | Destroyed | Travel VPN; torn down 2026-05-23 (regional-peers.yaml `status: destroyed`). |

The ephemeral travel-VPN tooling (transient AWS regions, on-demand teardown) is unused day-to-day; there are no standing regional peers. The sole standing AWS WireGuard peer is `vpn-aws` (us-west-2, EIP `44.240.60.80`, `vpn-usw2.etherport.net`) — the site-to-site hub described above. The former permanent east-coast endpoint was decommissioned 2026-07-01; Tailscale now covers east-coast/remote reach.

### Architecture

Regional VPNs use **direct wg0 tunnels** to homelab (not VPC peering transit) because AWS VPC peering doesn't support transit routing.

```
homelab K8s pod (10.255.255.2)
     │
     │ WireGuard wg0 (homelab dials the regional peer's static EIP :51820)
     ▼
regional peer (e.g. ap-south-1, tunnel IP 10.255.255.3-.6)
     │
     ├── AWS VPC (regional CIDR) → local egress
     │
     └── Homelab (10.10.192.0/19) → wg0 tunnel
```

### Deployment

See [Regional VPN Deployment Runbook](../runbooks/regional-vpn-deployment.md) for:
- Terraform deployment commands
- Client configuration
- Cost estimates (~$0.22/day)
- Teardown instructions

### When to Update This Section

Update this section whenever:
- A new regional VPN is deployed
- An existing regional VPN is destroyed
- IP assignments change

## VPN Endpoints

### K8s WireGuard Pod (Primary Local Gateway)

| Property | Value |
|----------|-------|
| Namespace | wireguard |
| Deployment | wireguard |
| Node Affinity | Any worker node (control-plane excluded); no per-node preference |
| VIP | 10.10.201.20 (managed by Keepalived sidecar) |
| Tunnel IP | 10.255.255.2/29 |
| Host/Listen Ports | wg0: 9820/UDP, wg1: 9821/UDP (hostPort = containerPort) |
| Public Key | `MwsTBFT0FPsZO+Bpe2Exk3y7oeIyv+HDx3j+lRSISTw=` |

**Managed by:** Flux (GitOps) from `platform/kubernetes/wireguard/`. (The pod listens on 9820/9821; `vpn-aws` still listens on 51820/51821, so the K8s peer block dials `44.240.60.80:51820`.)

### vpn-local (Backup Local Gateway)

| Property | Value |
|----------|-------|
| Hostname | vpn-local |
| LAN IP | 10.10.201.15 |
| VIP (when active) | 10.10.201.20 |
| Tunnel IP | 10.255.255.2/29 |
| VRRP Priority | 100 (backup) |
| Public Key | `MwsTBFT0FPsZO+Bpe2Exk3y7oeIyv+HDx3j+lRSISTw=` (same as K8s) |
| OS | Ubuntu 24.04 (x86_64) |

**Managed by:** Ansible (`playbooks/wireguard.yml`)

**Note:** K8s pod and vpn-local share the same WireGuard keys so AWS sees a single peer regardless of which is active.

### vpn-aws (AWS Gateway)

| Property | Value |
|----------|-------|
| Hostname | vpn-aws |
| Private IP | 10.10.100.10 |
| Public IP | 44.240.60.80 |
| Tunnel IPs | wg0: 10.255.255.1/29, wg1: 10.254.0.1/24 |
| Listen Ports | wg0: 51820, wg1: 51821 |
| Public Key (wg0) | `kHjcUM33FcpYWHgsE4Nwchaqky+iuJ7JfLTzC7lgOmU=` |
| Public Key (wg1) | `Aav0cNl4osaEEISQLyKLt88foAPwdVYaeTuyLF/PNTo=` |
| OS | Ubuntu 24.04 (ARM64/Graviton) |

**Interfaces:**
- **wg0**: Site-to-site tunnel to local homelab
- **wg1**: Remote access VPN for mobile clients (BACKUP to Tailscale)

**Managed by:** Ansible (`playbooks/wireguard.yml`)

## Deployment Methods

### K8s WireGuard (Primary)

Deployed via Flux from `platform/kubernetes/wireguard/`:

```bash
# Manual apply (Flux handles this automatically)
kubectl apply -k platform/kubernetes/wireguard/

# Check status
kubectl get pods -n wireguard
kubectl exec -n wireguard deployment/wireguard -c wireguard -- wg show wg0
```

### vpn-local and vpn-aws (Ansible)

```bash
cd infra/ansible

# All VPN servers
ansible-playbook -i inventory/wind/ -i inventory/aws/ playbooks/wireguard.yml

# Local only (vpn-local)
ansible-playbook -i inventory/wind/ playbooks/wireguard.yml --limit vpn-local

# AWS only
ansible-playbook -i inventory/aws/ playbooks/wireguard.yml --limit vpn-aws

# Check mode (dry-run)
ansible-playbook -i inventory/wind/ -i inventory/aws/ playbooks/wireguard.yml --check --diff
```

## Configuration Files

### K8s Pod: wg0.conf (embedded in deployment)

```ini
[Interface]
Address = 10.255.255.2/29
ListenPort = 9820
PrivateKey = <from secret>
MTU = 1420
# NAT for regional VPN traffic (so replies route back via wg0)
PostUp = iptables -t nat -I POSTROUTING 1 -s 10.255.255.0/29 -o eth0 -j MASQUERADE
PostUp = iptables -I FORWARD 1 -i wg0 -o eth0 -j ACCEPT
PostUp = iptables -I FORWARD 1 -i eth0 -o wg0 -j ACCEPT

[Peer]
# vpn-aws (us-west-2) - primary site-to-site
PublicKey = kHjcUM33FcpYWHgsE4Nwchaqky+iuJ7JfLTzC7lgOmU=
Endpoint = 44.240.60.80:51820
AllowedIPs = 10.10.100.0/22, 10.255.255.1/32
PersistentKeepalive = 25
```

### vpn-local: /etc/wireguard/wg0.conf

```ini
[Interface]
Address = 10.255.255.2/29
PrivateKey = <from local_private.key>
MTU = 1420

[Peer]
PublicKey = kHjcUM33FcpYWHgsE4Nwchaqky+iuJ7JfLTzC7lgOmU=
Endpoint = 44.240.60.80:51820
AllowedIPs = 10.10.100.0/22, 10.255.255.1/32
PersistentKeepalive = 25
```

### vpn-aws: /etc/wireguard/wg0.conf

```ini
[Interface]
Address = 10.255.255.1/29
ListenPort = 51820
PrivateKey = <from local_private.key>
MTU = 1420

[Peer]
PublicKey = MwsTBFT0FPsZO+Bpe2Exk3y7oeIyv+HDx3j+lRSISTw=
AllowedIPs = 10.255.255.2/32, 10.10.192.0/19
PersistentKeepalive = 25
```

### vpn-aws: /etc/wireguard/wg1.conf (BACKUP)

> **BACKUP:** wg1 is retained for restrictive networks. Use [Tailscale](vpn-tailscale.md) as the primary solution.

```ini
[Interface]
Address = 10.254.0.1/24
ListenPort = 51821
PrivateKey = <from aws_wg1_private.key>
MTU = 1420

[Peer]
# Graham (mobile)
PublicKey = 7FAI4YiWGRtKDl3AaG+jxjf0vDVaTtUisf68nQRFozA=
AllowedIPs = 10.254.0.10/32
```

## Routing

### UDM Pro Static Route

Traffic to AWS is routed via the floating VIP:

```
Destination: 10.10.100.0/22
Gateway: 10.10.201.20 (floating VIP)
```

This route remains stable regardless of whether K8s or vpn-local is active.

### vpn-aws Routes

```
default via 10.10.100.1 dev ens5
10.10.100.0/25 dev ens5 proto kernel       # AWS VPC subnet
10.10.192.0/19 dev wg0 scope link          # Local homelab via tunnel
10.254.0.0/24 dev wg1 proto kernel         # Remote access clients
10.255.255.0/29 dev wg0 proto kernel       # Tunnel network
```

## When to Use WireGuard vs Tailscale

| Scenario | Recommended | Reason |
|----------|-------------|--------|
| Home network | Tailscale | Direct peer connections, full speed |
| Office/coworking | Tailscale | NAT hole-punching usually works |
| Hotel/airport | **Try Tailscale first**, fallback to WireGuard | DERP may be slow (~1 Mbps) |
| Cellular/mobile | Tailscale | DERP handles CGNAT well |
| Large uploads (restrictive network) | WireGuard wg1 | Direct connection, no relay overhead |

**Why DERP can be slow:**

Tailscale uses DERP (Designated Encrypted Relay for Packets) when direct WireGuard connections can't be established. DERP relays are shared infrastructure with bandwidth limits (~1-5 Mbps per connection). Networks that block UDP or use aggressive NAT force all traffic through DERP, resulting in asymmetric speeds (fast download, slow upload).

WireGuard wg1 connects directly to vpn-aws's public IP (44.240.60.80:51821), bypassing DERP entirely.

## Adding a New Remote Client

> **Note:** Use [Tailscale](vpn-tailscale.md) as the primary solution. WireGuard wg1 is for backup/restrictive networks.

1. Generate keys on client:
   ```bash
   wg genkey | tee private.key | wg pubkey > public.key
   ```

2. Add peer to vpn-aws wg1.conf (via Ansible vars in `playbooks/wireguard.yml`):
   ```yaml
   wg1_peers:
     - name: "NewClient"
       public_key: "<client-public-key>"
       allowed_ips: "10.254.0.X/32"
   ```

3. Run Ansible:
   ```bash
   ansible-playbook -i inventory/aws/ playbooks/wireguard.yml --limit vpn-aws
   ```

4. Configure client with:
   - Server: 44.240.60.80:51821
   - Allowed IPs: 10.10.0.0/16, 10.254.0.0/24

## Troubleshooting

### Check K8s WireGuard Status

```bash
# Pod status
kubectl get pods -n wireguard

# Tunnel status
kubectl exec -n wireguard deployment/wireguard -c wireguard -- wg show wg0

# Keepalived status (VIP)
kubectl exec -n wireguard deployment/wireguard -c keepalived -- ip addr show | grep 10.10.201.20

# Logs
kubectl logs -n wireguard deployment/wireguard -c wireguard
kubectl logs -n wireguard deployment/wireguard -c keepalived
```

### Check vpn-local Status

```bash
# Via Ansible
ansible vpn-local -i inventory/wind/ -m shell -a "wg show wg0; ip addr show | grep 10.10.201.20"

# Keepalived logs
journalctl -u keepalived -f
```

### Check vpn-aws Status

```bash
ssh vpn-aws
sudo wg show
ping 10.255.255.2  # Local tunnel endpoint
```

### Verify Failover

```bash
# Scale down K8s WireGuard
kubectl scale deployment wireguard -n wireguard --replicas=0

# Check vpn-local acquired VIP
ansible vpn-local -m shell -a "ip addr show | grep 10.10.201.20"

# Check tunnel still works
ping 10.10.100.10

# Restore K8s
kubectl scale deployment wireguard -n wireguard --replicas=1
```

## MSS Clamping (MTU Fix)

To prevent TCP fragmentation issues over the VPN tunnel, vpn-aws runs nftables rules that clamp the MSS:

```nft
# /etc/nftables.conf on vpn-aws
table ip mangle {
  chain FORWARD {
    type filter hook forward priority mangle; policy accept;
    ip saddr 10.10.100.0/22 ip daddr 10.10.192.0/19 tcp flags syn / syn,rst counter tcp option maxseg size set rt mtu
    ip saddr 10.10.192.0/19 ip daddr 10.10.100.0/22 tcp flags syn / syn,rst counter tcp option maxseg size set rt mtu
  }
}
```

## Key Management

### Key File Locations

| Host | Key File | Purpose |
|------|----------|---------|
| K8s | Secret `wireguard-keys` | wg0 private key |
| vpn-local | /etc/wireguard/local_private.key | wg0 private key |
| vpn-aws | /etc/wireguard/local_private.key | wg0 private key |
| vpn-aws | /etc/wireguard/aws_wg1_private.key | wg1 private key |

### SOPS-Encrypted Key Storage

Keys are stored encrypted with SOPS:

```
platform/wireguard/servers/
├── vpn-aws.sops.yaml      # AWS us-west-2 keys (wg0 + wg1)
└── vpn-local.sops.yaml    # Local keys (wg0)

platform/kubernetes/wireguard/
└── 01-secrets.sops.yaml   # K8s secret (same keys as vpn-local)
```

**Important:** K8s and vpn-local use the SAME wg0 keys so AWS sees a single peer.

## Configuration Sync Status

> **⚠️ Snapshot — may be stale.** The sync table below reflects a point-in-time check (2026-05-03) and is not auto-verified. Confirm against the live `wg show` / Ansible run before relying on it.

All WireGuard endpoints are in sync as of 2026-05-03:

| Component | Git/Ansible | Running | Status |
|-----------|-------------|---------|--------|
| K8s pod wg0 | /29 | /29 | ✓ Synced |
| vpn-local wg0 | /29 | /29 | ✓ Synced |
| vpn-aws wg0 | /29 | /29 | ✓ Synced |

**Last sync:** Ansible applied to vpn-local and vpn-aws on 2026-05-03.

## Security Notes

- Private keys stored with 600 permissions, owned by root
- All keys encrypted at rest with SOPS/age
- PresharedKey can be added for post-quantum resistance
- AWS Security Groups allow UDP 51820/51821 from 0.0.0.0/0
- SSH access to vpn-aws only via VPN (no public SSH)
