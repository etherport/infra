# WireGuard VPN Configuration

## Overview

WireGuard configuration for the site-to-site VPN connecting local homelab to AWS.

**Primary gateway:** K8s WireGuard pod (managed via Flux)
**Backup gateway:** vpn-local VM (managed via Ansible)

For full architecture documentation, see [docs/architecture/vpn-wireguard.md](../../docs/architecture/vpn-wireguard.md).

## Directory Structure

```
platform/
├── wireguard/                    # Ansible-managed (vpn-local, vpn-aws)
│   ├── servers/                  # Server private/public keys
│   │   ├── vpn-aws.sops.yaml     # AWS VPN hub (wg0 + wg1)
│   │   └── vpn-local.sops.yaml   # Local backup gateway (wg0)
│   └── clients/                  # Client configurations
│       └── graham.sops.yaml      # Remote access client
│
└── kubernetes/wireguard/         # K8s primary gateway (Flux-managed)
    ├── 00-namespace.yaml
    ├── 01-secrets.sops.yaml      # Same keys as vpn-local
    ├── 02-configmap.yaml
    ├── 03-deployment.yaml        # WireGuard + Keepalived
    ├── 04-cleanup-daemonset.yaml # Orphan interface cleanup
    └── kustomization.yaml
```

## Decrypting Files

Requires the age key:

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
sops -d platform/wireguard/servers/vpn-aws.sops.yaml
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

## Key Rotation

To rotate server keys:

1. Generate new keys:
   ```bash
   wg genkey | tee private.key | wg pubkey > public.key
   ```

2. Update SOPS files:
   ```bash
   # For vpn-local and K8s (they share keys)
   sops platform/wireguard/servers/vpn-local.sops.yaml
   sops platform/kubernetes/wireguard/01-secrets.sops.yaml

   # For vpn-aws
   sops platform/wireguard/servers/vpn-aws.sops.yaml
   ```

3. Update peer public keys on the other side

4. Deploy:
   - K8s: Commit and push (Flux will apply)
   - VMs: Run Ansible playbook

## Architecture

```
                    Internet
                        │
                        ▼
              ┌─────────────────┐
              │    vpn-aws      │
              │  44.240.60.80   │
              │                 │
              │ wg0: S2S tunnel │◄────── VIP 10.10.201.20
              │ wg1: Remote VPN │        (K8s primary, vpn-local backup)
              └─────────────────┘
                        │
            ┌───────────┴───────────┐
            ▼                       ▼
    AWS VPC (10.10.100.0/22)   Homelab (10.10.192.0/19)
```

## Tunnel Details

| Tunnel | Purpose | Listen Port | Network |
|--------|---------|-------------|---------|
| wg0 | Site-to-site | 51820 | 10.255.255.0/30 |
| wg1 | Remote access (backup) | 51821 | 10.254.0.0/24 |

## Important Notes

- K8s and vpn-local share the SAME wg0 keys (AWS sees single peer)
- wg1 (remote access) only runs on vpn-aws
- VIP 10.10.201.20 floats between K8s and vpn-local via Keepalived
- UDM Pro routes to VIP, not to specific host IPs
