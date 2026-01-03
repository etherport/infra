# Technitium DNS Server

Technitium DNS Server deployment for homelab DNS services, replacing pi-hole + unbound + bind9.

## Architecture

- **Kubernetes StatefulSet**: 2 replicas with anti-affinity (VIP: 10.10.201.5)
- **Local Fallback VM**: Standalone instance at 10.10.201.6
- **AWS Instance**: Remote failover (clustered)

## Deployment

### 1. Create the Admin Secret

```bash
# Copy template and encrypt with SOPS
cp 05-secret.sops.yaml.template 05-secret.sops.yaml
sops 05-secret.sops.yaml
# Set a secure password, save and exit

# Deploy the secret
sops -d 05-secret.sops.yaml | kubectl apply -f -
```

### 2. Deploy the Stack

```bash
kubectl apply -k platform/kubernetes/technitium/
```

### 3. Verify Deployment

```bash
kubectl get pods -n dns
kubectl get svc -n dns
```

### 4. Access Web UI

- **Via Traefik**: https://dns.wind.etherport.net
- **Direct**: http://10.10.201.5:5380

## DNS Zone Configuration

After deployment, configure the `wind.etherport.net` zone via the web UI:

### Zone Setup

1. Go to **Zones** → **Add Zone**
2. Zone Name: `wind.etherport.net`
3. Type: **Primary Zone**

### DNS Records

Add the following A records:

| Hostname | IP Address | Notes |
|----------|------------|-------|
| `windroute` | 10.10.200.1 | Router |
| `pve` | 10.10.200.41 | Proxmox (direct access) |
| `vpn-local` | 10.10.201.15 | Local VPN |
| `vpn-aws` | 10.10.100.10 | AWS VPN |
| `print` | 10.10.202.20 | Printer |
| `gdisplay` | 10.10.202.45 | Google Display |
| `sequoia` | 10.10.209.10 | NAS/Storage |
| `protect` | 10.10.212.10 | UniFi Protect |
| `k8s-cp1` | 10.10.201.50 | K8s Control Plane |
| `k8s-w1` | 10.10.201.51 | K8s Worker 1 |
| `k8s-w2` | 10.10.201.52 | K8s Worker 2 |
| `k8s-gpu1` | 10.10.201.53 | K8s GPU Worker |

### Traefik-Managed Services (all point to 10.10.201.70)

These services are proxied through Traefik for SSL termination:

| Hostname | Target | Backend |
|----------|--------|---------|
| `traefik` | 10.10.201.70 | Traefik Dashboard |
| `plex` | 10.10.201.70 | Plex Media Server |
| `grafana` | 10.10.201.70 | Grafana Monitoring |
| `kopia` | 10.10.201.70 | Kopia Backup UI |
| `ha` | 10.10.201.70 | Home Assistant |
| `prox` | 10.10.201.70 | Proxmox Web UI (via Traefik) |
| `dns` | 10.10.201.70 | Technitium Web UI |
| `ups1` | 10.10.201.70 | UPS 1 Management |
| `ups2` | 10.10.201.70 | UPS 2 Management |
| `pdu1` | 10.10.201.70 | PDU 1 Management |
| `pdu2` | 10.10.201.70 | PDU 2 Management |

### Ad Blocking

1. Go to **Settings** → **Blocking**
2. Enable blocking
3. Add blocklists:
   - Steven Black's hosts: `https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts`
   - AdGuard DNS filter: `https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt`
   - Or import existing Pi-hole lists

### Recursive Resolution

Technitium supports recursive resolution out of the box:

1. Go to **Settings** → **Forwarders**
2. For recursive resolution, leave forwarders empty (Technitium will resolve directly)
3. Or add upstream forwarders:
   - Cloudflare: `1.1.1.1`, `1.0.0.1`
   - Google: `8.8.8.8`, `8.8.4.4`
   - Quad9: `9.9.9.9`

### DNSSEC

1. Go to **Settings** → **DNSSEC**
2. Enable DNSSEC validation

## Clustering

After all instances are running:

1. Access primary at http://10.10.201.5:5380
2. Go to **Settings** → **Clustering**
3. Enable clustering
4. Set a cluster secret (save this securely)
5. Add secondary nodes:
   - Local fallback: `10.10.201.6`
   - AWS instance: `<aws-ip>`
6. Zones will automatically sync across the cluster

## Failover Testing

```bash
# Test primary
dig @10.10.201.5 google.com

# Test fallback
dig @10.10.201.6 google.com

# Test ad blocking
dig @10.10.201.5 ads.google.com
# Should return NXDOMAIN or 0.0.0.0
```

## Maintenance

### View Logs

```bash
kubectl logs -n dns -l app=technitium -f
```

### Restart

```bash
kubectl rollout restart statefulset/technitium -n dns
```

### Backup

Zone data is stored in the PVC. Use Velero for backup:

```bash
velero backup create technitium-backup --include-namespaces dns
```

## Files

| File | Purpose |
|------|---------|
| `00-namespace.yaml` | DNS namespace |
| `01-configmap.yaml` | Technitium configuration |
| `02-statefulset.yaml` | StatefulSet + headless service |
| `03-service.yaml` | LoadBalancer service (VIP) |
| `04-ingressroute.yaml` | Traefik ingress for web UI |
| `05-secret.sops.yaml` | SOPS-encrypted admin password |
| `.sops.yaml` | SOPS encryption config |
