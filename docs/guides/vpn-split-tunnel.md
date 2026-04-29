# VPN Split Tunnel: NordVPN + Tailscale

## Overview

This guide enables simultaneous use of NordVPN for public internet traffic and Tailscale for private homelab/AWS traffic. Since NordVPN on macOS no longer offers split tunneling, we use the native WireGuard app with NordLynx credentials.

```
┌─────────────────────────────────────────────────────────────────┐
│                        Your Device                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────────┐         ┌──────────────────┐              │
│  │   WireGuard App  │         │    Tailscale     │              │
│  │   (NordLynx)     │         │                  │              │
│  │                  │         │                  │              │
│  │  AllowedIPs:     │         │  AllowedIPs:     │              │
│  │  0.0.0.0/0       │         │  100.x.x.x/10    │              │
│  │  MINUS:          │         │  10.10.x.x/16    │              │
│  │  - 10.0.0.0/8    │         │  (private nets)  │              │
│  │  - 100.64.0.0/10 │         │                  │              │
│  └────────┬─────────┘         └────────┬─────────┘              │
│           │                            │                         │
└───────────┼────────────────────────────┼─────────────────────────┘
            │                            │
            ▼                            ▼
    ┌───────────────┐           ┌───────────────┐
    │  NordVPN      │           │  Tailscale    │
    │  Server       │           │  Network      │
    │  (Internet)   │           │  (Private)    │
    └───────────────┘           └───────────────┘
```

## Prerequisites

- NordVPN subscription with NordLynx enabled
- WireGuard app installed (`brew install wireguard-tools` or App Store)
- Tailscale installed and connected
- `jq` and `curl` installed

## Step 1: Get NordLynx Credentials

NordVPN uses WireGuard under the hood (called NordLynx). Extract your private key:

```bash
# Get NordVPN access token (requires login)
# First, get your token from the NordVPN website:
# 1. Log in to https://my.nordaccount.com/
# 2. Go to Services → NordVPN
# 3. Generate an access token (or use existing)

# Set your access token
ACCESS_TOKEN="your-nordvpn-access-token"

# Get credentials from NordVPN API
curl -s -H "Authorization: token:$ACCESS_TOKEN" \
  "https://api.nordvpn.com/v1/users/services/credentials" | jq '.'
```

The response contains:
- `nordlynx_private_key` - Your WireGuard private key
- The key is unique to your account

Alternative method using NordVPN CLI:

```bash
# If NordVPN CLI is installed
nordvpn set technology nordlynx
nordvpn connect

# Find the interface
sudo wg show

# The private key will be shown (requires root)
# Copy it for use in WireGuard config
```

## Step 2: Choose a NordVPN Server

Find a fast server near you:

```bash
# Get recommended servers (US example)
curl -s "https://api.nordvpn.com/v1/servers/recommendations?filters\[country_id\]=228&filters\[servers_technologies\]\[identifier\]=wireguard_udp&limit=5" | \
  jq -r '.[] | "\(.name) - \(.station) - \(.hostname)"'

# Get server public key and endpoint
SERVER_HOSTNAME="us9999.nordvpn.com"  # Replace with chosen server
curl -s "https://api.nordvpn.com/v1/servers?filters\[hostname\]=$SERVER_HOSTNAME" | \
  jq -r '.[0].technologies[] | select(.identifier == "wireguard_udp") | .metadata[] | select(.name == "public_key") | .value'
```

## Step 3: Create WireGuard Config

Create the config file at `~/.wireguard/nordvpn.conf`:

```ini
[Interface]
# Your NordLynx private key (from Step 1)
PrivateKey = YOUR_NORDLYNX_PRIVATE_KEY
# NordVPN assigns this IP range to WireGuard clients
Address = 10.5.0.2/32
DNS = 103.86.96.100, 103.86.99.100

[Peer]
# NordVPN server public key (from Step 2)
PublicKey = SERVER_PUBLIC_KEY
# AllowedIPs: ALL traffic EXCEPT private ranges
# This routes internet through NordVPN while keeping Tailscale traffic local
AllowedIPs = 0.0.0.0/5, 8.0.0.0/7, 11.0.0.0/8, 12.0.0.0/6, 16.0.0.0/4, 32.0.0.0/3, 64.0.0.0/3, 96.0.0.0/6, 100.0.0.0/10, 100.128.0.0/9, 101.0.0.0/8, 102.0.0.0/7, 104.0.0.0/5, 112.0.0.0/4, 128.0.0.0/1
Endpoint = SERVER_HOSTNAME:51820
PersistentKeepalive = 25
```

### AllowedIPs Explanation

The AllowedIPs list covers all of `0.0.0.0/0` **except**:
- `10.0.0.0/8` - Private networks (homelab, AWS VPC)
- `100.64.0.0/10` - Tailscale CGNAT range (100.x.x.x addresses)

This means:
- Public internet traffic → NordVPN tunnel
- Tailscale traffic (100.x.x.x) → Tailscale interface
- Private network traffic (10.x.x.x) → Tailscale interface (via subnet routing)

## Step 4: Import to WireGuard App

### macOS (App Store version)
1. Open WireGuard app
2. Click `+` → "Import tunnel from file"
3. Select your `nordvpn.conf`
4. Activate the tunnel

### macOS (CLI)
```bash
# Import config
sudo wg-quick up ~/.wireguard/nordvpn.conf

# Verify
sudo wg show

# Stop
sudo wg-quick down ~/.wireguard/nordvpn.conf
```

## Step 5: Verify Split Tunnel

```bash
# Check public IP (should be NordVPN)
curl -s https://api.ipify.org && echo

# Check Tailscale connectivity (should work)
tailscale ping 100.75.199.69  # k8s-homelab-router

# Check homelab connectivity (should work via Tailscale)
ping 10.10.201.50  # Example homelab host

# Check AWS connectivity (should work via Tailscale)
ping 10.10.100.10  # vpn-aws
```

## Troubleshooting

### Tailscale Loses Connectivity

If Tailscale stops working when NordVPN WireGuard is active:

1. **Check AllowedIPs**: Ensure 100.64.0.0/10 and 10.0.0.0/8 are NOT in the NordVPN config
2. **Interface Priority**: macOS routes based on interface order. Tailscale should have higher priority for its ranges
3. **DNS Conflict**: Both configs set DNS. Consider removing DNS from NordVPN config if using Tailscale MagicDNS

### Connection Issues

```bash
# Check WireGuard interface
sudo wg show

# Check routing table
netstat -rn | grep -E '(utun|wg)'

# Check Tailscale routing
tailscale status
tailscale netcheck
```

### Regenerate AllowedIPs

If your private ranges change, regenerate the exclusion list:

```bash
# Ranges to exclude (customize as needed)
EXCLUDE_RANGES="10.0.0.0/8,100.64.0.0/10"

# This requires a subnet calculator - the 15 CIDR blocks above
# cover 0.0.0.0/0 minus the excluded ranges
# Use an online calculator like https://www.procustodibus.com/blog/2021/03/wireguard-allowedips-calculator/
```

## Performance Notes

- **Latency**: Adding NordVPN adds ~20-50ms depending on server distance
- **Bandwidth**: NordLynx (WireGuard) is efficient; expect near-full speeds
- **Battery**: Two VPN tunnels use more battery than one

## Alternative: Tailscale Exit Node

For simpler setup, use Tailscale exit nodes instead of NordVPN:

```bash
# Route all traffic through AWS (US IP)
tailscale set --exit-node=100.117.87.10  # vpn-aws

# Route all traffic through homelab (home IP)
tailscale set --exit-node=100.75.199.69  # k8s-homelab-router

# Split tunnel (only private traffic via Tailscale)
tailscale set --exit-node=
```

**Tailscale Exit Node Limitations:**
- Exit IP is your AWS or home IP (not privacy-focused like NordVPN)
- No server selection (limited to your infrastructure)
- Good for accessing geo-restricted content from "home"

## Related Documentation

- [Tailscale Mesh VPN](../architecture/vpn-tailscale.md)
- [WireGuard Infrastructure](../architecture/vpn-wireguard.md)
