#!/bin/bash
# WireGuard K8s Keys Setup Script
# This script helps populate the SOPS-encrypted secrets for the K8s WireGuard deployment
#
# Prerequisites:
#   - sops installed and configured with age key
#   - wg (wireguard-tools) installed
#   - Access to decrypt platform/wireguard/servers/vpn-fallback.sops.yaml
#
# Usage:
#   cd platform/kubernetes/wireguard
#   ./setup-keys.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
VPN_LOCAL_SOPS="$REPO_ROOT/platform/wireguard/servers/vpn-fallback.sops.yaml"
SECRETS_FILE="$SCRIPT_DIR/01-secrets.sops.yaml"

echo "WireGuard K8s Keys Setup"
echo "========================"
echo

# Check prerequisites
if ! command -v sops &> /dev/null; then
    echo "ERROR: sops is not installed"
    exit 1
fi

if ! command -v wg &> /dev/null; then
    echo "ERROR: wg (wireguard-tools) is not installed"
    exit 1
fi

# Step 1: Get wg0 keys from vpn-fallback
echo "Step 1: Extracting wg0 keys from vpn-fallback..."
if [ ! -f "$VPN_LOCAL_SOPS" ]; then
    echo "ERROR: Cannot find $VPN_LOCAL_SOPS"
    exit 1
fi

WG0_PRIVATE=$(sops -d "$VPN_LOCAL_SOPS" | grep 'wg0_private_key:' | awk '{print $2}')
WG0_PUBLIC=$(sops -d "$VPN_LOCAL_SOPS" | grep 'wg0_public_key:' | awk '{print $2}')

if [ -z "$WG0_PRIVATE" ]; then
    echo "ERROR: Could not extract wg0_private_key from vpn-fallback.sops.yaml"
    exit 1
fi

echo "  wg0 public key: $WG0_PUBLIC"

# Step 2: Generate new wg1 keys for local remote access
echo
echo "Step 2: Generating new wg1 keys for local remote access..."
WG1_PRIVATE=$(wg genkey)
WG1_PUBLIC=$(echo "$WG1_PRIVATE" | wg pubkey)

echo "  wg1 public key: $WG1_PUBLIC"
echo
echo "  IMPORTANT: Save this public key!"
echo "  Graham's client config needs to use this as the peer public key"
echo "  when connecting to the local WireGuard VPN."

# Step 3: Create the secrets file
echo
echo "Step 3: Creating secrets file..."

cat > "$SECRETS_FILE" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: wireguard-keys
  namespace: wireguard
type: Opaque
stringData:
  # wg0 keys - copied from vpn-fallback for failover compatibility
  wg0-private.key: "$WG0_PRIVATE"
  wg0-public.key: "$WG0_PUBLIC"
  # wg1 keys - new keys for local remote access
  wg1-private.key: "$WG1_PRIVATE"
  wg1-public.key: "$WG1_PUBLIC"
EOF

# Step 4: Encrypt with SOPS
echo
echo "Step 4: Encrypting secrets with SOPS..."
sops -e -i "$SECRETS_FILE"

echo
echo "Done! Secrets file created and encrypted: $SECRETS_FILE"
echo
echo "Next steps:"
echo "  1. Update vpn-fallback to also have wg1 with these same keys"
echo "  2. Update Graham's WireGuard client config with the new wg1 public key:"
echo "     PublicKey = $WG1_PUBLIC"
echo "  3. Commit the changes and let Flux deploy"
echo
echo "Client configuration for Graham (local wg1):"
echo "============================================"
cat <<CLIENTCONF
[Interface]
PrivateKey = <graham's private key>
Address = 10.254.0.10/32
DNS = 10.10.201.5, 1.1.1.1

[Peer]
PublicKey = $WG1_PUBLIC
AllowedIPs = 10.10.100.0/22, 10.10.192.0/19, 10.254.0.0/24, 10.255.255.0/30
Endpoint = <homelab-dynamic-dns>:51821
PersistentKeepalive = 25
CLIENTCONF
