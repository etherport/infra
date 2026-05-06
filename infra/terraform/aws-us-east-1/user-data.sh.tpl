#!/bin/bash
# US-East-1 Hub VPN Bootstrap Script
#
# Architecture:
#   - wg0: Direct tunnel to homelab (required because VPC peering doesn't support transit routing)
#   - wg1: Remote access for your devices
#   - VPC Peering: Used for us-west-2 hub traffic
#
# Traffic Flow:
#   - Internet → NAT via Elastic IP
#   - AWS us-west-2 VPC (10.10.100.0/22) → VPC Peering → us-west-2
#   - Homelab (10.10.192.0/19) → wg0 → homelab WireGuard pod

set -euo pipefail
exec > >(tee /var/log/user-data.log) 2>&1

echo "=== Starting VPN bootstrap $(date) ==="

# Update and install packages
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
# Homelab initiates connection to us (avoids port forward/DDNS issues)
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
# No Endpoint - homelab initiates connection to us (static Elastic IP)
PublicKey = ${homelab_wg0_public_key}
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

[Peer]
# Your device (Graham)
PublicKey = ${client_public_key}
AllowedIPs = 10.254.0.10/32
EOF

chmod 600 /etc/wireguard/*.conf

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
echo "  - Internet → NAT → Elastic IP"
echo "  - ${homelab_cidr} → wg0 tunnel → homelab"
echo "  - ${aws_vpc_cidr} → VPC Peering → us-west-2"
echo "  - ${local_vpc_cidr} → local VPC"
