# NordVPN Meshnet Kubernetes Endpoint

This deployment creates a NordVPN Meshnet peer in the K8s cluster, allowing you to:
- Connect to NordVPN for internet privacy (exit through NordVPN servers)
- Access homelab resources via Meshnet while connected to NordVPN
- Route specific traffic (homelab subnets) through the Meshnet peer

## Architecture

```
Your Device (traveling)
├── Internet traffic → NordVPN servers (privacy)
└── Homelab traffic → Meshnet → homelab-k8s.nord → K8s cluster → homelab
```

## Setup Steps

### 1. Generate NordVPN Access Token

1. Go to https://my.nordaccount.com/dashboard/nordvpn/
2. Click "Set up NordVPN manually"
3. Verify your email
4. Generate a new access token (set expiration as desired)
5. Copy the token

### 2. Encrypt the Token

```bash
cd platform/kubernetes/nordvpn-meshnet

# Edit the secret file with your token
# Replace REPLACE_WITH_NORDVPN_ACCESS_TOKEN with your actual token

# Encrypt with SOPS
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops -e -i 01-secret.sops.yaml
```

### 3. Add to Flux

Add to `clusters/wind/kustomization.yaml`:
```yaml
resources:
  # ...
  - ../../platform/kubernetes/nordvpn-meshnet
```

### 4. Deploy

```bash
git add -A && git commit -m "Add NordVPN Meshnet endpoint"
git push
```

### 5. Link Your Devices

After deployment, the node will appear in your NordVPN Meshnet as `homelab-k8s.nord`.

On your devices:
1. Open NordVPN app
2. Go to Meshnet
3. Find `homelab-k8s.nord` in your devices
4. Enable routing permissions

## Usage

When traveling with NordVPN connected:

1. **For privacy**: Regular internet traffic goes through NordVPN servers
2. **For homelab access**:
   - In NordVPN app, enable "Route traffic through this device" for `homelab-k8s.nord`
   - Or add specific routes in your system for homelab subnets

### Split Tunneling Example (macOS)

```bash
# Route homelab traffic through Meshnet peer
sudo route add -net 10.10.192.0/19 <meshnet-peer-ip>
sudo route add -net 10.10.100.0/22 <meshnet-peer-ip>
```

## Troubleshooting

### Check pod status
```bash
kubectl get pods -n nordvpn-meshnet
kubectl logs -n nordvpn-meshnet deploy/nordvpn-meshnet
```

### Check Meshnet status
```bash
kubectl exec -n nordvpn-meshnet deploy/nordvpn-meshnet -- nordvpn status
kubectl exec -n nordvpn-meshnet deploy/nordvpn-meshnet -- nordvpn meshnet peer list
```

### Check routing
```bash
kubectl exec -n nordvpn-meshnet deploy/nordvpn-meshnet -- ip route
```

## References

- [MattsTechInfo/Meshnet](https://github.com/MattsTechInfo/Meshnet) - Community Docker image
- [NordVPN Meshnet Docs](https://meshnet.nordvpn.com/)
