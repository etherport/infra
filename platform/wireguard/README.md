# WireGuard VPN Configuration

## Overview

WireGuard configuration is stored encrypted with SOPS and deployed via Ansible.

## Directory Structure

```
platform/wireguard/
├── servers/           # Server private/public keys
│   ├── vpn-aws.sops.yaml      # AWS VPN hub (wg0 + wg1)
│   └── vpn-local.sops.yaml    # Local site gateway (wg0)
└── clients/           # Client configurations
    ├── graham.sops.yaml       # Remote access client
    └── vpn-local-s2s.sops.yaml # S2S client (for DR reference)
```

## Decrypting Files

Requires the age key:

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
sops -d platform/wireguard/servers/vpn-aws.sops.yaml
```

## Deploying Configuration

Use the Ansible playbook:

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

2. Update SOPS file:
   ```bash
   sops platform/wireguard/servers/vpn-local.sops.yaml
   # Edit the keys
   ```

3. Update peer public keys on the other side (AWS or local)

4. Run Ansible playbook to deploy

## Architecture

```
                    Internet
                        │
                        ▼
              ┌─────────────────┐
              │    vpn-aws      │
              │  44.240.60.80   │
              │                 │
              │ wg0: S2S tunnel │◄────── vpn-local (10.10.201.15)
              │ wg1: Remote VPN │◄────── Remote clients
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
| wg1 | Remote access | 51821 | 10.254.0.0/24 |
