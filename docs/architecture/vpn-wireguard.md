# WireGuard VPN Infrastructure

## Overview

Site-to-site VPN connecting local homelab to AWS. This is the **production traffic path** for ALB-routed services.

**Note:** For remote client access, [Tailscale](vpn-tailscale.md) is the primary solution.

> **BACKUP:** WireGuard wg1 (remote access) is retained as a backup for restrictive networks where Tailscale's DERP relay performance is insufficient. See [When to Use WireGuard vs Tailscale](#when-to-use-wireguard-vs-tailscale) below.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         WireGuard VPN Topology                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Local Homelab                           AWS (us-west-2)                   │
│   ┌─────────────────┐                     ┌─────────────────┐               │
│   │  vpn-local      │◄───── wg0 ─────────►│  vpn-aws        │               │
│   │  10.10.201.15   │     (site-to-site)  │  10.10.100.10   │               │
│   │                 │                     │                 │               │
│   │  Tunnel IP:     │                     │  Tunnel IP:     │               │
│   │  10.255.255.2   │                     │  10.255.255.1   │               │
│   └────────┬────────┘                     └────────┬────────┘               │
│            │                                       │                        │
│            │ Routes to AWS:                        │ Routes to Local:       │
│            │ 10.10.100.0/22                        │ 10.10.192.0/19         │
│            │ 10.254.0.0/24                         │                        │
│            │                                       │                        │
│   ┌────────▼────────┐                     ┌────────▼────────┐               │
│   │  Local Network  │                     │  AWS VPC        │               │
│   │  10.10.0.0/16   │                     │  10.10.100.0/24 │               │
│   │                 │                     │                 │               │
│   │  VLANs:         │                     │  Instances:     │               │
│   │  - 200: Mgmt    │                     │  - dns-aws (.5) │               │
│   │  - 201: Servers │                     │  - vpn-aws (.10)│               │
│   │  - 202: Clients │                     │                 │               │
│   │  - 204: IoT     │                     └─────────────────┘               │
│   │  - etc.         │                                                       │
│   └─────────────────┘                              ▲                        │
│                                                    │                        │
│                                           ┌────────┴────────┐               │
│                                           │  wg1 (remote)   │               │
│                                           │  10.254.0.0/24  │               │
│                                           │  [BACKUP]       │               │
│                                           │  For slow DERP  │               │
│                                           └─────────────────┘               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Network Addressing

| Network | CIDR | Purpose |
|---------|------|---------|
| 10.255.255.0/30 | Site-to-site tunnel | Point-to-point link between sites |
| 10.254.0.0/24 | Remote access | Mobile/roaming client VPN |
| 10.10.192.0/19 | Local homelab | All local VLANs (10.10.192.0 - 10.10.223.255) |
| 10.10.100.0/22 | AWS networks | AWS VPC and related (10.10.100.0 - 10.10.103.255) |

## VPN Endpoints

### vpn-local (Local Site Gateway)

| Property | Value |
|----------|-------|
| Hostname | vpn-local.wind.etherport.net |
| LAN IP | 10.10.201.15 |
| Tunnel IP | 10.255.255.2/30 |
| Listen Port | 51216 |
| Public Key | `MwsTBFT0FPsZO+Bpe2Exk3y7oeIyv+HDx3j+lRSISTw=` |
| OS | Ubuntu 24.04 (x86_64) |

**Routes advertised to AWS:**
- 10.10.192.0/19 (all local VLANs)

**Routes received from AWS:**
- 10.10.100.0/22 (AWS VPC)
- 10.254.0.0/24 (remote access clients)

### vpn-aws (AWS Site Gateway)

| Property | Value |
|----------|-------|
| Hostname | vpn-aws.wind.etherport.net |
| Private IP | 10.10.100.10 |
| Public IP | 44.240.60.80 |
| Tunnel IPs | wg0: 10.255.255.1/30, wg1: 10.254.0.1/24 |
| Listen Ports | wg0: 51820, wg1: 51821 |
| Public Key (wg0) | `kHjcUM33FcpYWHgsE4Nwchaqky+iuJ7JfLTzC7lgOmU=` |
| Public Key (wg1) | `Aav0cNl4osaEEISQLyKLt88foAPwdVYaeTuyLF/PNTo=` |
| OS | Ubuntu 24.04 (ARM64/Graviton) |

**Interfaces:**
- **wg0**: Site-to-site tunnel to local homelab
- **wg1**: Remote access VPN for mobile clients

## Configuration Files

### vpn-local: /etc/wireguard/wg0.conf

```ini
[Interface]
Address = 10.255.255.2/30
MTU = 1420
# PrivateKey in /etc/wireguard/local_private.key

# Peer: AWS hub
[Peer]
PublicKey = kHjcUM33FcpYWHgsE4Nwchaqky+iuJ7JfLTzC7lgOmU=
Endpoint = 44.240.60.80:51820
AllowedIPs = 10.10.100.0/22, 10.255.255.1/32, 10.254.0.0/24
PersistentKeepalive = 25
```

### vpn-aws: /etc/wireguard/wg0.conf

```ini
[Interface]
Address = 10.255.255.1/30
ListenPort = 51820
MTU = 1420
# PrivateKey in /etc/wireguard/local_private.key

# Peer: Local site router
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
MTU = 1420
# PrivateKey in /etc/wireguard/aws_wg1_private.key

[Peer]
# Graham (mobile)
PublicKey = 7FAI4YiWGRtKDl3AaG+jxjf0vDVaTtUisf68nQRFozA=
AllowedIPs = 10.254.0.10/32
```

## Routing Tables

### vpn-local

```
default via 10.10.201.1 dev eth0
10.10.100.0/22 dev wg0 scope link          # AWS via tunnel
10.10.201.0/24 dev eth0 proto kernel       # Local VLAN
10.254.0.0/24 dev wg0 scope link           # Remote clients via AWS
10.255.255.0/30 dev wg0 proto kernel       # Tunnel network
```

### vpn-aws

```
default via 10.10.100.1 dev ens5
10.10.100.0/25 dev ens5 proto kernel       # AWS VPC subnet
10.10.192.0/19 dev wg0 scope link          # Local homelab via tunnel
10.254.0.0/24 dev wg1 proto kernel         # Remote access clients
10.255.255.0/30 dev wg0 proto kernel       # Tunnel network
```

## System Configuration

Both endpoints have IP forwarding enabled:

```bash
# /etc/sysctl.d/99-wg-forward.conf
net.ipv4.ip_forward=1
```

## Service Management

```bash
# Enable and start WireGuard
sudo systemctl enable wg-quick@wg0
sudo systemctl start wg-quick@wg0

# Check status
sudo wg show

# Restart after config change
sudo systemctl restart wg-quick@wg0
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

2. Add peer to vpn-aws wg1.conf:
   ```ini
   [Peer]
   # Client Name
   PublicKey = <client-public-key>
   AllowedIPs = 10.254.0.X/32
   ```

3. Restart wg1:
   ```bash
   sudo systemctl restart wg-quick@wg1
   ```

4. Configure client with:
   - Server: 44.240.60.80:51821
   - Allowed IPs: 10.10.0.0/16, 10.254.0.0/24

## Troubleshooting

```bash
# Check tunnel status
sudo wg show

# Test connectivity
ping 10.255.255.1  # From local to AWS tunnel
ping 10.255.255.2  # From AWS to local tunnel

# Check routes
ip route

# View logs
sudo journalctl -u wg-quick@wg0 -f
```

## MSS Clamping (MTU Fix)

To prevent TCP fragmentation issues over the VPN tunnel, vpn-aws runs nftables rules that clamp the MSS (Maximum Segment Size) on forwarded traffic:

```nft
# /etc/nftables.conf on vpn-aws
table ip mangle {
  chain FORWARD {
    type filter hook forward priority mangle; policy accept;
    # Clamp MSS for traffic from AWS to local homelab
    ip saddr 10.10.100.0/22 ip daddr 10.10.192.0/19 tcp flags syn / syn,rst counter tcp option maxseg size set rt mtu
    # Clamp MSS for traffic from local homelab to AWS
    ip saddr 10.10.192.0/19 ip daddr 10.10.100.0/22 tcp flags syn / syn,rst counter tcp option maxseg size set rt mtu
  }
}
```

This ensures that TCP connections negotiate an appropriate MSS that accounts for the WireGuard encapsulation overhead, preventing packet fragmentation.

## Key File Locations

| Host | Key File | Purpose |
|------|----------|---------|
| vpn-local | /etc/wireguard/local_private.key | wg0 private key |
| vpn-local | /etc/wireguard/local_public.key | wg0 public key |
| vpn-aws | /etc/wireguard/local_private.key | wg0 private key |
| vpn-aws | /etc/wireguard/local_public.key | wg0 public key |
| vpn-aws | /etc/wireguard/aws_wg1_private.key | wg1 private key |
| vpn-aws | /etc/wireguard/aws_wg1_public.key | wg1 public key |

## Ansible Management

WireGuard configuration is managed via Ansible:

```bash
# Deploy WireGuard config to all VPN servers
cd infra/ansible
ansible-playbook -i inventory/wind/ -i inventory/aws/ playbooks/wireguard.yml

# Check mode (dry-run)
ansible-playbook -i inventory/wind/ -i inventory/aws/ playbooks/wireguard.yml --check --diff

# Target only vpn-local
ansible-playbook -i inventory/wind/ playbooks/wireguard.yml --limit vpn-local

# Target only vpn-aws
ansible-playbook -i inventory/aws/ playbooks/wireguard.yml --limit vpn-aws
```

The playbook manages:
- WireGuard package installation
- IP forwarding (sysctl)
- wg0.conf and wg1.conf configuration
- nftables MSS clamping rules (AWS only)
- systemd service enablement

**Note:** Private keys are NOT managed by Ansible. Keys must already exist on the hosts.

## Security Notes

- Private keys are stored in separate files with 600 permissions
- Key files owned by root:root
- PresharedKey can be added for additional security (post-quantum resistance)
- AWS Security Groups must allow UDP 51820/51821 from 0.0.0.0/0
- Local firewall (UDM Pro) must allow UDP 51216 outbound
- SSH access only via VPN (no public SSH on vpn-aws)
