#!/bin/bash
# Regional VPN Bootstrap Script
# Installs and configures WireGuard on first boot

set -euo pipefail
exec > >(tee /var/log/user-data.log) 2>&1

echo "=== Starting VPN bootstrap $(date) ==="

# Wait for cloud-init to complete
cloud-init status --wait

# Update and install packages
apt-get update
apt-get install -y wireguard wireguard-tools

# Enable IP forwarding
cat > /etc/sysctl.d/99-wireguard.conf << 'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl -p /etc/sysctl.d/99-wireguard.conf

# Create WireGuard directory
mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

# Configure wg0 - Site-to-site tunnel to homelab
cat > /etc/wireguard/wg0.conf << 'EOF'
[Interface]
Address = ${wg_address}
ListenPort = 51820
PrivateKey = ${wg_private_key}

# NAT for traffic going to homelab
PostUp = iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o wg0 -j MASQUERADE

[Peer]
# Homelab (K8s WG / vpn-local)
PublicKey = ${wg_peer_public_key}
Endpoint = ${wg_peer_endpoint}
AllowedIPs = ${wg_peer_allowed_ips}
PersistentKeepalive = 25
EOF

# Configure wg1 - Remote access for your devices
cat > /etc/wireguard/wg1.conf << 'EOF'
[Interface]
Address = 10.254.0.1/24
ListenPort = 51821
PrivateKey = ${wg_private_key}

# NAT for internet egress and homelab access
PostUp = iptables -t nat -A POSTROUTING -o ens5 -j MASQUERADE
PostUp = iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o ens5 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o wg0 -j MASQUERADE

[Peer]
# Your device
PublicKey = ${client_public_key}
AllowedIPs = ${client_allowed_ips}
EOF

chmod 600 /etc/wireguard/*.conf

# Enable and start WireGuard
systemctl enable wg-quick@wg0
systemctl enable wg-quick@wg1
systemctl start wg-quick@wg0
systemctl start wg-quick@wg1

# Verify
sleep 2
wg show

echo "=== VPN bootstrap complete $(date) ==="
