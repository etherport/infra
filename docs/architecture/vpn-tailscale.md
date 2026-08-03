# Tailscale Mesh VPN

## Overview

Tailscale provides mesh VPN connectivity for remote client access as a supplement to the WireGuard site-to-site tunnel.

While WireGuard handles AWS↔homelab traffic routing, Tailscale enables:

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
│   │  k8s-homelab-router │    │  vpn-fallback       │    │  vpn-aws        │ │
│   │  (K8s Connector)    │    │  (exit node ONLY)   │    │  (Subnet Router)│ │
│   │  SOLE /19 ROUTER    │    │                     │    │                 │ │
│   │  Routes:            │    │  Routes: NONE       │    │  Routes:        │ │
│   │  10.10.192.0/19     │    │  (/19 = manual      │    │  10.10.100.0/22 │ │
│   │  (on-prem)          │    │   break-glass)      │    │  (AWS ONLY)     │ │
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
| AWS ↔ On-prem production traffic | WireGuard (wg0) | Fixed topology, predictable routing for the site-to-site tunnel |
| Remote client access | Tailscale | Easy onboarding, MagicDNS, split DNS |
| Direct device-to-device | Tailscale | Mesh routing without hub bottleneck |

### Critical: accept-routes Configuration

The vpn-aws server runs **both** WireGuard and Tailscale. To prevent Tailscale from overriding WireGuard routes:

```bash
# vpn-aws MUST have accept-routes=false
tailscale set --accept-routes=false
```

If `--accept-routes=true`, Tailscale will accept routes from `k8s-homelab-router`, causing traffic to 10.10.201.x to go via Tailscale instead of WireGuard. This breaks the AWS→homelab path over the site-to-site tunnel (e.g. the edge box's Technitium DNS replica sync and any service reached from AWS via wg0 start timing out).

## Components

### Tailscale Kubernetes Operator

Deployed via Flux in the `tailscale` namespace:

```yaml
# clusters/wind/helm-releases/tailscale-operator.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: tailscale-operator
  namespace: flux-system
spec:
  targetNamespace: tailscale  # operator pods run here
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

### Static endpoint (DERP-fallback fix for the subnet router) — M154, 2026-07-25

The Connector's `proxyClass` is `static-endpoint-router` (`platform/kubernetes/tailscale/`
ProxyClass CR), which pins `tailscaled` to a fixed UDP port and advertises a dialable WAN
endpoint so peers with hard NATs can hole-punch to the subnet router instead of silently
falling back to a slow DERP relay:

```yaml
# ProxyClass static-endpoint-router
spec:
  statefulSet:
    pod:
      tailscaleContainer:
        env:
        - name: TS_TAILSCALED_EXTRA_ARGS
          value: --port=41641
        - name: TS_DEBUG_PRETENDPOINT
          value: <homelab-WAN-IP>:41641   # must be updated if the WAN IP changes
```

A LoadBalancer Service exposes that fixed port on the MetalLB VIP so the UDM can forward
WAN traffic to it:

| Property | Value |
|----------|-------|
| Service | `ts-router-static-endpoint` (namespace `tailscale`) |
| VIP | 10.10.201.74 |
| Port | 41641/UDP |

**Native Tailscale `staticEndpoints` only advertises node ExternalIPs**, which doesn't fit
this cluster's topology (no node has the WAN IP), hence the `TS_DEBUG_PRETENDPOINT` env-var
workaround + explicit VIP/UDM-forward path instead. ⚠️ **The advertised endpoint goes stale
if the homelab WAN IP changes** — update `TS_DEBUG_PRETENDPOINT` (and the UDM port-forward)
to match, or peers silently fall back to DERP again. Tell direct-vs-relay via `tailscale
status`/`tailscale ping` (empty `curaddr` + a `relay` set = DERP fallback).

### Sole-advertiser model (no TS auto-failover) — M149/M150, 2026-07-25

**The K8s Connector is the ONLY `10.10.192.0/19` advertiser. There is deliberately no
automatic TS failover.** The retired `tailscale-failover` unit on vpn-fallback (and
vpn-aws's static `/19` advert) caused the 2026-07 hairpin incident, for two reasons:

1. **Primary election preempts and never fails back.** The control plane re-elects the
   subnet-route primary on *every* advertiser change, with a fixed preference
   `vpn-aws > vpn-fallback > k8s-homelab-router` — the K8s router only routes while it is
   the *sole* advertiser. Any standby advert silently steals the primary even when the
   K8s router is healthy: via vpn-aws = all TS clients hairpin through AWS; via
   vpn-fallback = MetalLB VIPs blackhole (VLAN-201 hosts can't reach BGP VIPs).
2. **The failover script pinged a hardcoded Connector Tailscale IP** that went stale when
   the Connector was recreated → "router down" forever → permanent standby advert.

**If the K8s router is actually down:** the WG VIP (`10.10.201.20`, keepalived) is the
*automatic* backup path; TS subnet routing has a *manual* break-glass —
[`docs/runbooks/tailscale-route-failback.md`](../runbooks/tailscale-route-failback.md).
The `tailscale-route-drift` CI detector (every 6h) alerts if any standby re-advertises
the `/19` or the Connector loses it.

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

> The `100.x` Tailscale IPs below are stable assignments, but prefer the MagicDNS hostname (`vpn-aws`, `k8s-homelab-router`, `vpn-fallback`) in commands — the IP can change if a node is removed and re-added.

| Node | Tailscale IP | Exit Location | Use Case |
|------|--------------|---------------|----------|
| vpn-aws | 100.117.87.10 | AWS us-west-2 | Privacy, US exit |
| k8s-homelab-router | 100.126.218.72 | Home ISP | Appear at home (primary) |
| vpn-fallback | 100.97.20.113 | Home ISP | Appear at home (backup) |

k8s-homelab-router and vpn-fallback are **both approved** exit nodes in the tailnet.
vpn-fallback re-registered as a tagged device after the M128 `vpn-local` →
`vpn-fallback` rename (new node, hence the new 100.x IP).

### Usage

```bash
# Route ALL traffic through AWS (privacy mode)
tailscale set --exit-node=100.117.87.10

# Route ALL traffic through homelab (appear at home)
tailscale set --exit-node=100.126.218.72

# Disable exit node (split tunnel - only private traffic via Tailscale)
tailscale set --exit-node=
```

### Shell Aliases

Add to `~/.zshrc` for convenience:

```bash
alias ts-split='/Applications/Tailscale.app/Contents/MacOS/Tailscale set --exit-node='
alias ts-aws='/Applications/Tailscale.app/Contents/MacOS/Tailscale set --exit-node=100.117.87.10'
alias ts-home='/Applications/Tailscale.app/Contents/MacOS/Tailscale set --exit-node=100.126.218.72'
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
| etherport.net | 10.10.201.5, 10.10.201.6, 10.10.100.10 |

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
  vpn-aws: "10.10.100.0/22"  # AWS VPC ONLY — never the homelab /19 (M149/M150)
  vpn-fallback: ""           # exit-node only — /19 is manual break-glass

tailscale_host_accept_routes:
  vpn-aws: false   # Critical: prevents WireGuard route override
  vpn-fallback: false # Has WireGuard - don't accept Tailscale routes

tailscale_advertise_exit_node:
  vpn-aws: true    # Allow using vpn-aws as exit node
  vpn-fallback: true  # Backup exit node
```

The playbook REMOVES the retired `tailscale-failover` unit from vpn-fallback if present
(see the sole-advertiser section above for why auto-failover is unsafe here), and its
`tailscale set` task passes `--advertise-routes` explicitly even when empty, so a run
CLEARS any drifted advert rather than leaving it in place.

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

### AWS→homelab traffic over wg0 times out

**Symptom:** Traffic from AWS to on-prem (e.g. the edge box `vpn-aws` reaching `10.10.201.x`, or anything routed over the site-to-site tunnel) stalls/times out.

**Cause:** vpn-aws has `--accept-routes=true`, accepting routes from k8s-homelab-router via Tailscale, so on-prem traffic takes the Tailscale path instead of wg0.

**Fix:**
```bash
ssh vpn-aws
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
