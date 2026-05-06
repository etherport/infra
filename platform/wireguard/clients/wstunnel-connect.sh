#!/bin/bash
# WireGuard over wstunnel (TCP) for use with NordVPN or restrictive networks
#
# Usage:
#   1. Start this script FIRST (keeps running in foreground)
#   2. Then enable the "AWS-VPN-TCP" WireGuard profile
#   3. To stop: Ctrl+C this script, then disable WireGuard
#
# This tunnels WireGuard UDP through a WebSocket (TCP 443) connection,
# bypassing networks that block UDP or VPN traffic.

set -e

# wstunnel server endpoint
SERVER="vpn-usw2.etherport.net"
SERVER_PORT="443"

# Local port to listen on (WireGuard will connect here)
LOCAL_PORT="51821"

# Remote WireGuard port on server
REMOTE_PORT="51821"

echo "Starting wstunnel client..."
echo "  Local:  UDP 127.0.0.1:${LOCAL_PORT}"
echo "  Remote: WSS ${SERVER}:${SERVER_PORT} -> UDP 127.0.0.1:${REMOTE_PORT}"
echo ""
echo "Now enable the 'AWS-VPN-TCP' WireGuard profile."
echo "Press Ctrl+C to stop."
echo ""

# Run wstunnel client
# -L udp://LOCAL:PORT:REMOTE:PORT - Forward local UDP to remote UDP
# --tls-verify-certificate false - Accept self-signed cert on server
exec wstunnel client \
    --tls-verify-certificate false \
    -L "udp://127.0.0.1:${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}" \
    "wss://${SERVER}:${SERVER_PORT}"
