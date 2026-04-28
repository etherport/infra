# Tailscale Mesh VPN

## Overview

Tailscale provides mesh VPN connectivity for remote client access as a supplement to the WireGuard site-to-site tunnel. While WireGuard handles production traffic routing between AWS and the homelab, Tailscale enables:

- Direct device-to-device connections without hub routing
- Easy client onboarding without manual key exchange
- MagicDNS for automatic name resolution
- Split DNS for internal domain resolution
- Exit nodes for routing all traffic through homelab or AWS

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      Tailscale + WireGuard Architecture                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Remote Clients                    Tailscale Mesh                          │
│   ┌──────────────┐              ┌─────────────────────┐                     │
│   │ Laptop/Phone │◄─────────────┤  100.x.x.x network  │                     │
│   │ Tailscale    │  Tailscale   │  (Tailnet)          │                     │
│   └──────────────┘  Protocol    └──────────┬──────────┘                     │
│                                            │                                │
│                     ┌──────────────────────┼──────────────────────┐         │
│                     │                      │                      │         │
│                     ▼                      ▼                      ▼         │
│   ┌─────────────────────┐    ┌─────────────────────┐    ┌─────────────────┐ │
│   │  k8s-homelab-router │    │  vpn-local          │    │  vpn-aws        │ │
│   │  (K8s Connector)    │    │  (BACKUP router)    │    │  (Subnet Router)│ │
│   │  PRIMARY            │    │                     │    │                 │ │
│   │  Routes:            │    │  Routes:            │    │  Routes:        │ │
│   │  10.10.192.0/19     │    │  10.10.192.0/19     │    │  10.10.100.0/22 │ │
│   │  (on-prem)          │    │  (failover only)    │    │  (AWS)          │ │
│   └──────────┬──────────┘    └──────────┬──────────┘    └────────┬────────┘ │
│              │                          │                                   │
│              │                          │ (NOT via Tailscale)               │
│              │                          │                                   │
│              ▼                          ▼                                   │
│   ┌─────────────────────┐    ┌─────────────────────┐                        │
│   │  Local Network      │    │  AWS VPC            │                        │
│   │  10.10.192.0/19     │◄───┤  10.10.100.0/22     │                        │
│   │                     │    │                     │                        │
│   │  (via WireGuard     │  WG│  vpn-aws uses WG    │                        │
│   │   site-to-site)     │    │  for this traffic   │                        │
│   └─────────────────────┘    └─────────────────────┘                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Design Decisions

### Why Both WireGuard and Tailscale?

| Use Case | Solution | Reason |
|----------|----------|--------|
| AWS ↔ On-prem production traffic | WireGuard (wg0) | Fixed topology, predictable routing for ALB ingress |
| Remote client access | Tailscale | Easy onboarding, MagicDNS, split DNS |
| Direct device-to-device | Tailscale | Mesh routing without hub bottleneck |

### Critical: accept-routes Configuration

The vpn-aws server runs **both** WireGuard and Tailscale. To prevent Tailscale from overriding WireGuard routes:

```bash
# vpn-aws MUST have accept-routes=false
tailscale set --accept-routes=false
```

If `--accept-routes=true`, Tailscale will accept routes from `k8s-homelab-router`, causing traffic to 10.10.201.x to go via Tailscale instead of WireGuard. This breaks ALB connectivity (504 Gateway Timeout).

## Components

### Tailscale Kubernetes Operator

Deployed via Flux in the `tailscale` namespace:

```yaml
# clusters/wind/helm-releases/tailscale-operator.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: tailscale-operator
  namespace: tailscale
spec:
  chart:
    spec:
      chart: tailscale-operator
      sourceRef:
        kind: HelmRepository
        name: tailscale
```

### Kubernetes Connector (Subnet Router)

Advertises on-prem routes to the Tailnet:

```yaml
# platform/kubernetes/tailscale/connector/connector.yaml
apiVersion: tailscale.com/v1alpha1
kind: Connector
metadata:
  name: homelab-subnet-router
  namespace: tailscale
spec:
  hostname: k8s-homelab-router
  exitNode: true  # Allow routing all traffic through homelab
  subnetRouter:
    advertiseRoutes:
      - "10.10.192.0/19"  # On-prem homelab
  tags:
    - "tag:subnet-router"
```

### vpn-local Backup Router

vpn-local runs as a backup subnet router with automatic failover. When the K8s Connector is down, vpn-local takes over advertising on-prem routes:

```bash
# Failover script monitors K8s router every 10s
# After 3 consecutive failures, vpn-local advertises routes
# When K8s recovers, vpn-local releases routes

# Systemd service: tailscale-failover.service
# Script: /usr/local/bin/tailscale-failover.sh
```

**Failover Behavior:**

| K8s Router State | vpn-local Routes | Notes |
|------------------|------------------|-------|
| UP | None (standby) | K8s is primary |
| DOWN (3+ checks) | 10.10.192.0/19 | Auto-failover |
| Recovered | None (releases) | K8s resumes primary |

The failover script checks K8s router via `tailscale ping 100.70.241.55`. Routes are approved in Tailscale admin but only advertised during failover.

### AWS VPN Server Tailscale

Advertises AWS subnet to the Tailnet:

```bash
# Installed via Ansible (playbooks/tailscale.yml)
tailscale up \
  --hostname=vpn-aws \
  --advertise-routes=10.10.100.0/22 \
  --advertise-tags=tag:subnet-router \
  --advertise-exit-node
```

## Exit Nodes

Exit nodes allow routing **all** traffic through a Tailscale node, not just private subnet traffic. This provides privacy when traveling or access to geo-restricted content.

### Available Exit Nodes

| Node | Tailscale IP | Exit Location | Use Case |
|------|--------------|---------------|----------|
| vpn-aws | 100.117.87.10 | AWS us-west-2 | Privacy, US exit |
| k8s-homelab-router | 100.70.241.55 | Home ISP | Appear at home (primary) |
| vpn-local | 100.73.247.54 | Home ISP | Appear at home (backup) |

### Usage

```bash
# Route ALL traffic through AWS (privacy mode)
tailscale set --exit-node=100.117.87.10

# Route ALL traffic through homelab (appear at home)
tailscale set --exit-node=100.117.63.43

# Disable exit node (split tunnel - only private traffic via Tailscale)
tailscale set --exit-node=
```

### Shell Aliases

Add to `~/.zshrc` for convenience:

```bash
alias ts-split='/Applications/Tailscale.app/Contents/MacOS/Tailscale set --exit-node='
alias ts-aws='/Applications/Tailscale.app/Contents/MacOS/Tailscale set --exit-node=100.117.87.10'
alias ts-home='/Applications/Tailscale.app/Contents/MacOS/Tailscale set --exit-node=100.117.63.43'
alias ts-status='/Applications/Tailscale.app/Contents/MacOS/Tailscale status'
```

## DERP Relay Behavior

When direct WireGuard connections can't be established, Tailscale falls back to DERP (Designated Encrypted Relay for Packets).

### When DERP is Used

| Network Type | Connection | Expected Speed |
|--------------|------------|----------------|
| Home network | Direct | Full symmetric |
| Office/coworking | Usually direct | Full symmetric |
| Hotel/airport | DERP relay | ~30-50 Mbps down, ~1-5 Mbps up |
| Cellular/CGNAT | DERP relay | Variable |

### Checking Connection Type

```bash
# Shows "direct" or "relay" for each peer
tailscale status

# Detailed ping showing DERP relay if used
tailscale ping 100.117.87.10
# Direct: "pong from vpn-aws (100.117.87.10) in 45ms"
# Relay:  "pong from vpn-aws (100.117.87.10) via DERP(dbi) in 270ms"
```

### DERP Limitations

DERP relays are shared infrastructure with soft bandwidth limits (~1-5 Mbps per connection). For large uploads on restrictive networks, consider using [WireGuard wg1](vpn-wireguard.md#when-to-use-wireguard-vs-tailscale) as a backup.

## Split DNS Configuration

Internal domains resolve to internal DNS servers via Tailscale's split DNS:

| Domain | Nameservers |
|--------|-------------|
| etherport.net | 10.10.201.5, 10.10.201.6, 10.10.100.5 |

Configure in [Tailscale Admin Console](https://login.tailscale.com/admin/dns) → DNS → Add nameservers → Restrict to domain.

## Tailscale ACL Configuration

The Tailscale ACL (Access Control List) must be configured in the [Tailscale Admin Console](https://login.tailscale.com/admin/acls):

```json
{
  "tagOwners": {
    "tag:subnet-router": ["tag:subnet-router", "autogroup:admin"],
    "tag:k8s-operator": ["tag:k8s-operator", "autogroup:admin"],
    "tag:k8s": ["tag:k8s-operator", "autogroup:admin"]
  },
  "acls": [
    {"action": "accept", "src": ["*"], "dst": ["*:*"]}
  ]
}
```

**Important:** Tags must own themselves for OAuth client bootstrapping.

## Ansible Management

### Installation

```bash
# Install/configure Tailscale on AWS VPN server
ansible-playbook -i inventory/aws/ playbooks/tailscale.yml --limit vpn-aws

# First-time installation requires auth key
ansible-playbook -i inventory/aws/ playbooks/tailscale.yml \
  -e "tailscale_auth_key=tskey-auth-..."
```

### Configuration

The playbook manages per-host settings:

```yaml
# From playbooks/tailscale.yml
tailscale_advertise_routes:
  vpn-aws: "10.10.100.0/22"
  vpn-local: ""  # Empty - failover script controls this

tailscale_host_accept_routes:
  vpn-aws: false   # Critical: prevents WireGuard route override
  vpn-local: false # Has WireGuard - don't accept Tailscale routes

tailscale_advertise_exit_node:
  vpn-aws: true    # Allow using vpn-aws as exit node
  vpn-local: true  # Backup exit node
```

The playbook also deploys the failover script and systemd service on vpn-local.

## Comparison: WireGuard wg1 vs Tailscale

| Feature | WireGuard wg1 | Tailscale |
|---------|---------------|-----------|
| Key exchange | Manual public key swap | Automatic via coordination server |
| Client IP assignment | Manual (10.254.0.x) | Automatic (100.x.x.x) |
| NAT traversal | Manual port forwarding | Automatic (DERP relays) |
| DNS | Manual configuration | MagicDNS + Split DNS |
| ACLs | Firewall rules | Tailscale ACL policies |
| Multi-device per user | Separate keys each | Single identity |
| Exit node support | No (subnet routing only) | Yes (route all traffic) |
| Restrictive network speed | Direct connection (fast) | DERP relay (may be slow) |

**Recommendation:** Use Tailscale as primary. Retain WireGuard wg1 as backup for large uploads on restrictive networks where DERP is slow.

## Verifying Configuration

### Check Tailscale Status

```bash
# On vpn-aws
tailscale status

# Verify routes being advertised
tailscale status --json | jq '.Self.AdvertisedRoutes'

# Verify accept-routes is OFF (critical for vpn-aws)
tailscale debug prefs | grep -i acceptroutes
```

### Verify Routing Doesn't Conflict

```bash
# On vpn-aws, traffic to on-prem should use WireGuard, not Tailscale
ip route get 10.10.201.70
# Expected: 10.10.201.70 dev wg0 src 10.255.255.1

# NOT this (would indicate Tailscale override):
# 10.10.201.70 dev tailscale0 ...
```

## Troubleshooting

### 504 Gateway Timeout on ALB Services

**Symptom:** Services like ha.wind.etherport.net return 504 when accessed via ALB.

**Cause:** vpn-aws has `--accept-routes=true`, accepting routes from k8s-homelab-router via Tailscale.

**Fix:**
```bash
ssh ubuntu@10.10.100.10
sudo tailscale set --accept-routes=false
```

### Tailscale Operator OAuth Errors

**Symptom:** `400 tags not permitted` or `401` errors.

**Fix:** Update ACL to have tags own themselves:
```json
"tagOwners": {
  "tag:k8s-operator": ["tag:k8s-operator", "autogroup:admin"]
}
```

### Route Not Approved

**Symptom:** Subnet routes show as pending.

**Fix:** Approve routes in [Tailscale Admin Console](https://login.tailscale.com/admin/machines) → select machine → Approve routes.

## Related Documentation

- [WireGuard Infrastructure](vpn-wireguard.md) - Site-to-site VPN (production traffic)
- [AWS Infrastructure](aws-infrastructure.md) - VPC and EC2 configuration
- [Network Architecture](network.md) - Overall network design
