# Tailscale Operator

Tailscale mesh VPN for remote client access to homelab resources.

## Architecture

```
Remote Clients (Mac, Phone, etc.)
         |
    [Tailscale]
         |
    +----+----+
    |         |
  Direct    DERP Relay (fallback)
    |         |
    +----+----+
         |
         v
    K8s Subnet Router (this)
         |
    On-Prem Network (10.10.192.0/19)
```

## Benefits over WireGuard

- **Mesh networking**: Direct connections between devices when possible
- **NAT traversal**: Works through restrictive networks (NordVPN, hotel WiFi, etc.)
- **DERP relays**: Automatic fallback when UDP is blocked
- **Simple client setup**: Install app, login, done
- **Lower latency**: Direct connections bypass AWS transit

## Setup Instructions

### 1. Create Tailscale Account

Go to https://login.tailscale.com and create an account (free tier supports 100 devices).

### 2. Create OAuth Client

1. Go to https://login.tailscale.com/admin/settings/oauth
2. Click "Generate OAuth client"
3. Select scopes:
   - `devices:read`
   - `devices:write`
   - `routes:read`
   - `routes:write`
4. Copy the Client ID and Client Secret

### 3. Configure ACL Tags

In Tailscale admin console, go to Access Controls and add:

```json
{
  "tagOwners": {
    "tag:k8s-operator": ["autogroup:admin"],
    "tag:subnet-router": ["autogroup:admin"],
    "tag:homelab": ["autogroup:admin"]
  },
  "acls": [
    {
      "action": "accept",
      "src": ["autogroup:members"],
      "dst": ["*:*"]
    }
  ],
  "autoApprovers": {
    "routes": {
      "10.10.192.0/19": ["tag:subnet-router"]
    }
  }
}
```

### 4. Encrypt OAuth Credentials

Edit `01-oauth-secret.sops.yaml` with your OAuth credentials:

```bash
# Edit the file with your credentials
vim 01-oauth-secret.sops.yaml

# Encrypt with SOPS
sops -e -i 01-oauth-secret.sops.yaml
```

### 5. Deploy

Commit and push - Flux will deploy automatically:

```bash
git add .
git commit -m "Add Tailscale operator for mesh VPN"
git push
```

Or force reconciliation (no flux CLI on the hosts — CLAUDE.md §3):

```bash
kubectl annotate -n flux-system gitrepository/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
kubectl annotate -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
```

### 6. Approve Routes

After the Connector is created, approve the subnet routes in Tailscale admin console:
https://login.tailscale.com/admin/machines

Look for `k8s-homelab-router` and approve the advertised routes.

### 7. Install Tailscale on Clients

- macOS: `brew install --cask tailscale`
- iOS/Android: Install from App Store / Play Store
- Login with your Tailscale account

## Files

| File | Description |
|------|-------------|
| `01-oauth-secret.sops.yaml` | OAuth credentials for operator (SOPS encrypted) |
| `connector/connector.yaml` | Subnet router configuration |

## Troubleshooting

```bash
# Check operator status
kubectl -n tailscale get pods
kubectl -n tailscale logs deployment/tailscale-operator

# Check connector status
kubectl -n tailscale get connectors
kubectl -n tailscale describe connector homelab-subnet-router

# Force restart
kubectl -n tailscale rollout restart deployment/tailscale-operator
```

## Related

- HelmRelease: `clusters/wind/helm-releases/tailscale-operator.yaml`
- Helm repo: `clusters/wind/helm-releases/repositories.yaml` (tailscale)
