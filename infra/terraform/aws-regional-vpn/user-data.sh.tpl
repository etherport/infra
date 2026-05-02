#!/bin/bash
# Regional VPN Bootstrap Script
#
# Architecture:
#   - wg0: Direct tunnel to homelab (required because VPC peering doesn't support transit routing)
#   - wg1: Remote access for your devices
#   - VPC Peering: Used for AWS VPC traffic (10.10.100.0/22 routes via peering to us-west-2)
#
# Traffic Flow:
#   - Internet → NAT via local public IP
#   - AWS VPC (10.10.100.0/22) → VPC Peering → us-west-2 (direct, no tunnel)
#   - Homelab (10.10.192.0/19) → wg0 → homelab WireGuard pod (direct tunnel)

set -euo pipefail
exec > >(tee /var/log/user-data.log) 2>&1

echo "=== Starting VPN bootstrap $(date) ==="

# Update and install packages (don't wait for cloud-init - can cause deadlock)
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard wireguard-tools iptables-persistent

# Enable IP forwarding
cat > /etc/sysctl.d/99-wireguard.conf << 'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl -p /etc/sysctl.d/99-wireguard.conf

# Create WireGuard directory
mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

# Configure wg0 - Direct tunnel to homelab
# Required because VPC peering doesn't support transit routing
cat > /etc/wireguard/wg0.conf << 'EOF'
[Interface]
Address = ${wg0_tunnel_ip}/32
ListenPort = 51820
PrivateKey = ${wg0_private_key}

# NAT traffic going to homelab so return packets come back through tunnel
PostUp = iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o wg0 -j MASQUERADE

[Peer]
# Homelab WireGuard pod
PublicKey = ${homelab_wg0_public_key}
Endpoint = ${homelab_endpoint}:51820
AllowedIPs = ${homelab_cidr}, 10.255.255.2/32
PersistentKeepalive = 25
EOF

# Configure wg1 - Remote access for your devices
cat > /etc/wireguard/wg1.conf << 'EOF'
[Interface]
Address = 10.254.0.1/24
ListenPort = 51821
PrivateKey = ${wg1_private_key}

# NAT for internet egress (public traffic)
PostUp = iptables -t nat -A POSTROUTING -s 10.254.0.0/24 -o ens5 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s 10.254.0.0/24 -o ens5 -j MASQUERADE

# Note: No NAT needed for homelab traffic - wg0 handles that routing
# VPN clients send to 10.10.192.0/19, this host routes via wg0 (not VPC peering)

[Peer]
# Your device (Graham)
PublicKey = ${client_public_key}
AllowedIPs = 10.254.0.10/32
EOF

chmod 600 /etc/wireguard/*.conf

# Add route for homelab via wg0 (more specific than VPC peering route)
# This ensures homelab traffic goes through wg0 tunnel, not VPC peering
# (VPC peering can't transit through vpn-aws's wg0 tunnel)

# Enable and start WireGuard
systemctl enable wg-quick@wg0 wg-quick@wg1
systemctl start wg-quick@wg0
systemctl start wg-quick@wg1

# Save iptables rules for persistence
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4

# Verify
sleep 2
echo "=== WireGuard Status ==="
wg show

echo "=== Route Table ==="
ip route

echo "=== VPN bootstrap complete $(date) ==="
echo ""
echo "Traffic routing:"
echo "  - Internet → NAT → local public IP"
echo "  - ${homelab_cidr} → wg0 tunnel → homelab"
echo "  - ${aws_vpc_cidr} → VPC Peering → us-west-2"
