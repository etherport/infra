# WireGuard VPN Configuration

## Overview

WireGuard VPN infrastructure providing:
- **Site-to-site tunnel (wg0)**: Connects homelab to AWS
- **Remote access (wg1)**: Direct VPN for mobile/travel use

**Endpoints:**
| Endpoint | Hostname | wg1 Port | Use Case |
|----------|----------|----------|----------|
| Homelab (K8s/vpn-local) | wind.etherport.net | 9821 | Direct, fastest |
| AWS US-West-2 | vpn-usw2.etherport.net | 51821 | West coast relay (ephemeral) |
| AWS US-East-1 | vpn-use1.etherport.net | 51821 | East coast relay — **ACTIVE** standing peer |

For full architecture documentation, see [docs/architecture/vpn-wireguard.md](../../docs/architecture/vpn-wireguard.md).

## Client Configuration

### Extracting Configs from SOPS

Client configs are stored encrypted. To extract:

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

# View all configs
sops -d platform/wireguard/clients/graham.sops.yaml

# Extract specific config to file
sops -d platform/wireguard/clients/graham.sops.yaml | \
  yq '.stringData["aws-split.conf"]' > ~/wg-aws-split.conf
```

### Available Profiles

| Profile | Endpoint | Traffic | DNS |
|---------|----------|---------|-----|
| homelab-split | wind.etherport.net:9821 | Homelab only | Homelab DNS |
| homelab-full | wind.etherport.net:9821 | All traffic | Homelab DNS |
| usw2-split | vpn-usw2.etherport.net:51821 | Homelab only | AWS DNS |
| usw2-full | vpn-usw2.etherport.net:51821 | All traffic | AWS DNS |
| use1-split | vpn-use1.etherport.net:51821 | Homelab only | AWS DNS |
| use1-full | vpn-use1.etherport.net:51821 | All traffic | AWS DNS |

### Security Best Practices

**Private keys are secrets.** Handle them accordingly:

1. **Never commit plaintext keys** - Always use SOPS encryption
2. **Secure distribution**:
   - Use a password manager (1Password, Bitwarden)
   - Send via encrypted channel (Signal, encrypted email)
   - Generate QR code locally, scan directly (don't save image)
3. **Per-device keys** (ideal): Generate unique keypairs per device so you can revoke individually
4. **Rotate compromised keys immediately**: Update SOPS files, redeploy, update all clients

### Adding a New Client

1. Generate keypair:
   ```bash
   wg genkey | tee /tmp/client-private.key | wg pubkey > /tmp/client-public.key
   ```

2. Add peer to server configs:
   - `infra/ansible/playbooks/wireguard.yml` (wg1_peers list)
   - Redeploy with Ansible

3. Create client SOPS file:
   ```bash
   cp platform/wireguard/clients/graham.sops.yaml platform/wireguard/clients/newclient.sops.yaml
   sops platform/wireguard/clients/newclient.sops.yaml
   # Update PrivateKey, Address (use next available 10.254.0.X)
   ```

4. Securely send config to client

## Directory Structure

```
platform/
├── wireguard/                    # Ansible-managed (vpn-local, vpn-aws, vpn-use1)
│   ├── regional-peers.yaml       # Auto-generated peer list (GitHub Actions — do not edit)
│   ├── servers/                  # Server private/public keys
│   │   ├── vpn-aws.sops.yaml     # AWS VPN hub (wg0 + wg1)
│   │   ├── vpn-local.sops.yaml   # Local backup gateway (wg0 + wg1)
│   │   └── vpn-use1.sops.yaml    # AWS us-east-1 keys (permanent regional peer)
│   └── clients/                  # Client configurations
│       ├── graham.sops.yaml      # Remote access client configs
│       ├── graham-tcp.conf.template  # WireGuard-over-TCP (wstunnel) profile
│       ├── vpn-local-s2s.sops.yaml   # Local site-to-site client keys
│       └── wstunnel-connect.sh   # WG-over-TCP helper (NordVPN/restrictive nets)
│
└── kubernetes/wireguard/         # K8s primary gateway (Flux-managed)
    ├── 00-namespace.yaml
    ├── 01-secrets.sops.yaml      # Same wg0/wg1 keys as vpn-local
    ├── 03-deployment.yaml        # WireGuard + Keepalived
    ├── 04-cleanup-daemonset.yaml # Orphan interface cleanup
    └── kustomization.yaml
```

## Deployment

### K8s (Primary) - via Flux

Changes to `platform/kubernetes/wireguard/` are automatically deployed by Flux.

Manual apply:
```bash
kubectl apply -k platform/kubernetes/wireguard/
```

### vpn-local and vpn-aws - via Ansible

```bash
cd infra/ansible
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

# All VPN servers
ansible-playbook -i inventory/wind/ -i inventory/aws/ playbooks/wireguard.yml

# Local only
ansible-playbook -i inventory/wind/ playbooks/wireguard.yml --limit vpn-local

# AWS only
ansible-playbook -i inventory/aws/ playbooks/wireguard.yml --limit vpn-aws
```

## Key Management

### Shared Key Strategy

For seamless failover, keys are shared:
- **wg0**: K8s pod + vpn-local use same keys (AWS sees single peer)
- **wg1**: K8s pod + vpn-local + vpn-aws use same keys (clients can switch endpoints)

### Key Rotation

1. Generate new keys:
   ```bash
   wg genkey | tee private.key | wg pubkey > public.key
   ```

2. Update SOPS files:
   ```bash
   # For homelab (K8s + vpn-local share keys)
   sops platform/wireguard/servers/vpn-local.sops.yaml
   sops platform/kubernetes/wireguard/01-secrets.sops.yaml

   # For vpn-aws
   sops platform/wireguard/servers/vpn-aws.sops.yaml
   ```

3. Update peer public keys on remote side

4. Deploy:
   - K8s: Commit and push (Flux will apply)
   - VMs: Run Ansible playbook

## Network Requirements

### UDM Port Forwards

Required port forwards for homelab WireGuard endpoints:

| Name | WAN Port | Forward IP | Forward Port | Protocol | Purpose |
|------|----------|------------|--------------|----------|---------|
| WireGuard wg0 | 9820 | 10.10.201.20 | 51820 | UDP | Regional VPN tunnels (Mumbai, etc.) |
| WireGuard wg1 | 9821 | 10.10.201.20 | 9821 | UDP | Direct remote access |

Configure in UDM: Network → Port Forwarding → Create

**Why port 9820 for wg0?** Ports 10000-60000 are used by Twilio for voice/SIP traffic. Port 51820 falls within this range, so we use 9820 externally and forward to 51820 internally.

**Note:** vpn-aws endpoints (vpn-usw2.etherport.net:51820/51821) work without local port forwards since it's a cloud VM with a public IP.

## Architecture

```
                         REMOTE CLIENT
                              │
           ┌──────────────────┼──────────────────┐
           │                  │                  │
           ▼                  ▼                  ▼
    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
    │   HOMELAB   │    │    AWS      │    │  TAILSCALE  │
    │ :9821 (wg1) │    │ :51821(wg1) │    │    DERP     │
    └──────┬──────┘    └──────┬──────┘    └─────────────┘
           │                  │
           │    VIP 10.10.201.20
           │    (K8s primary, vpn-local backup)
           │                  │
           │                  │ wg0 site-to-site
           │                  │ (always up)
           ▼                  ▼
    ┌─────────────────────────────────────────────────┐
    │                    HOMELAB                       │
    │              10.10.192.0/19                     │
    └─────────────────────────────────────────────────┘
```

## Tunnel Details

| Tunnel | Purpose | Port (Homelab External) | Port (Homelab Internal) | Port (AWS) | Network |
|--------|---------|-------------------------|-------------------------|------------|---------|
| wg0 | Site-to-site + Regional | 9820 | 51820 | 51820 | 10.255.255.0/29 |
| wg1 | Remote access | 9821 | 9821 | 51821 | 10.254.0.0/24 |

**Note:** Regional VPNs (Mumbai, etc.) connect INBOUND to homelab's wg0 via port 9820. The vpn-aws connection is OUTBOUND from homelab, so it doesn't need a port forward.

## Troubleshooting

### Check interface status
```bash
# K8s
kubectl exec -n wireguard deployment/wireguard -c wireguard -- wg show

# vpn-local/vpn-aws
ssh vpn-local "sudo wg show"
ssh vpn-aws "sudo wg show"
```

### Check VIP assignment
```bash
kubectl exec -n wireguard deployment/wireguard -c keepalived -- ip addr | grep 10.10.201.20
```

### Force failover test
```bash
# Scale down K8s to trigger failover to vpn-local
kubectl scale deployment wireguard -n wireguard --replicas=0

# Check VIP moved to vpn-local
ssh vpn-local "ip addr | grep 10.10.201.20"

# Restore
kubectl scale deployment wireguard -n wireguard --replicas=1
```
