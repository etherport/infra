# Technitium DNS Server

Technitium DNS Server deployment for homelab DNS services, replacing pi-hole + unbound + bind9.

## Architecture

```
                         ┌─────────────────────────────────────────────┐
                         │           Technitium DNS Cluster            │
                         └─────────────────────────────────────────────┘

   ┌─────────────────────────────────────────────────────────────────────────┐
   │                        Kubernetes (Primary)                             │
   │                                                                         │
   │   ┌─────────────────────┐       ┌─────────────────────┐                │
   │   │    technitium-0     │       │    technitium-1     │                │
   │   │   (cluster primary) │◄─────►│  (cluster secondary)│                │
   │   │   10.10.201.71      │       │   10.10.201.72      │                │
   │   └─────────────────────┘       └─────────────────────┘                │
   │              │                                                          │
   │              └─────────► LoadBalancer VIP: 10.10.201.5                  │
   └─────────────────────────────────────────────────────────────────────────┘
                                        │
                          Zone Sync (Catalog + AXFR)
                                        │
          ┌─────────────────────────────┼─────────────────────────────┐
          │                             │                             │
          ▼                             │                             ▼
   ┌─────────────────┐                  │                  ┌─────────────────┐
   │  Local Fallback │                  │                  │  AWS Instance   │
   │  10.10.201.6    │◄─────────────────┴─────────────────►│  10.10.100.5    │
   │  (secondary)    │                                     │  (secondary)    │
   └─────────────────┘                                     └─────────────────┘
```

### Service IPs

| Service | IP | Purpose |
|---------|-----|---------|
| Main LoadBalancer | 10.10.201.5 | Primary DNS VIP (clients use this) |
| technitium-0 | 10.10.201.71 | Cluster primary pod (for clustering) |
| technitium-1 | 10.10.201.72 | Cluster secondary pod (for clustering) |
| Local Fallback | 10.10.201.6 | Standalone VM (secondary) |
| AWS Instance | 10.10.100.5 | Remote failover (secondary) |

## Deployment

### 1. Create the Admin Secret

```bash
# Copy template and edit
cp 05-secret.sops.yaml.template 05-secret.sops.yaml
sops 05-secret.sops.yaml
# Set username and password, save and exit
```

### 2. Deploy via Flux or kubectl

```bash
# Via Flux (recommended)
git add -A && git commit -m "Deploy Technitium" && git push
flux reconcile kustomization flux-system

# Or direct apply
kubectl apply -k platform/kubernetes/technitium/
```

### 3. Verify Deployment

```bash
kubectl get pods -n dns
kubectl get svc -n dns
dig @10.10.201.5 google.com
```

### 4. Access Web UI

- **Via Traefik**: https://dns.wind.etherport.net
- **Direct (primary)**: http://10.10.201.71:5380
- **Direct (VIP)**: http://10.10.201.5:5380

## GitOps Zone Management

DNS records are managed via GitOps. Zone files in `zones/` are synced to Technitium automatically.

### Adding/Modifying DNS Records

1. Edit the zone file:
   ```bash
   vim zones/wind.etherport.net.yaml
   ```

2. Add a record:
   ```yaml
   records:
     - name: myservice
       type: A
       value: 10.10.201.100
       comment: My new service
   ```

3. Commit and push:
   ```bash
   git add -A
   git commit -m "Add DNS record for myservice"
   git push
   ```

4. The `dns-sync-watcher` deployment detects changes and syncs to all cluster nodes.

### Zone File Format

```yaml
zone: wind.etherport.net
ttl: 3600  # Default TTL

records:
  - name: hostname      # Use @ for apex
    type: A             # A, AAAA, CNAME, MX, TXT, SRV, CAA
    value: 10.10.201.x
    ttl: 3600           # Optional, overrides default
    comment: Description
```

### Supported Record Types

| Type | Value Format | Example |
|------|--------------|---------|
| A | IPv4 address | `10.10.201.70` |
| AAAA | IPv6 address | `2001:db8::1` |
| CNAME | Hostname | `target.example.com` |
| MX | `priority exchange` | `10 mail.example.com` |
| TXT | Text string | `v=spf1 include:...` |

## Clustering

The cluster uses Technitium's catalog zone feature for automatic zone synchronization:

- **Primary**: technitium-0 (10.10.201.71) hosts the primary catalog zone
- **Secondaries**: All other nodes subscribe to the catalog and receive zone updates

### Cluster Configuration

Clustering is pre-configured. To add a new secondary node:

1. Install Technitium on the new server
2. Access primary UI at https://dns.wind.etherport.net
3. Go to **Settings** → **Clustering**
4. Add the new node's IP to the cluster

### Zone Transfer Settings

Zone transfers use catalog zones. The catalog automatically provisions member zones on secondaries. ACLs are configured to allow:
- Kubernetes pod network: `10.42.0.0/16`
- Local fallback: `10.10.201.6`
- AWS instance: `10.10.100.5`

## DNS Records (wind.etherport.net)

Current records are defined in `zones/wind.etherport.net.yaml`.

### Infrastructure

| Hostname | IP | Description |
|----------|-----|-------------|
| k8s-cp1 | 10.10.201.50 | Kubernetes control plane |
| k8s-w1 | 10.10.201.51 | Kubernetes worker 1 |
| k8s-w2 | 10.10.201.52 | Kubernetes worker 2 |
| k8s-w3 | 10.10.201.53 | Kubernetes worker 3 |
| k8s-gpu1 | 10.10.201.60 | Kubernetes GPU worker |
| traefik | 10.10.201.70 | Traefik ingress VIP |
| dns | 10.10.201.70 | DNS web UI (via Traefik) |
| dns-fallback | 10.10.201.6 | Local DNS fallback |
| dns-aws | 10.10.100.5 | AWS DNS failover |

### Network Equipment

| Hostname | IP | Description |
|----------|-----|-------------|
| windroute | 10.10.200.1 | UDM Pro router |
| pve | 10.10.200.41 | Proxmox VE hypervisor |
| sequoia | 10.10.209.10 | NAS/storage |

### Applications (via Traefik at 10.10.201.70)

| Hostname | Description |
|----------|-------------|
| grafana | Grafana monitoring |
| ha | Home Assistant |
| plex | Plex media server |
| kopia | Kopia backup UI |
| prox | Proxmox web UI proxy |
| wiki | Wiki.js |
| ups1, ups2 | UPS management |
| pdu1, pdu2 | PDU management |

### VPN

| Hostname | IP | Description |
|----------|-----|-------------|
| vpn-local | 10.10.201.15 | WireGuard local endpoint |
| vpn-aws | 10.10.100.10 | WireGuard AWS endpoint |

### Devices

| Hostname | IP | Description |
|----------|-----|-------------|
| protect | 10.10.212.10 | UniFi Protect NVR |
| print | 10.10.202.20 | Network printer |
| gdisplay | 10.10.202.45 | Display/workstation |

## Ad Blocking

1. Go to **Settings** → **Blocking**
2. Enable blocking
3. Add blocklists:
   - Steven Black: `https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts`
   - AdGuard: `https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt`

## Maintenance

### View Logs

```bash
# StatefulSet pods
kubectl logs -n dns -l app=technitium -f

# GitOps sync watcher
kubectl logs -n dns deployment/dns-sync-watcher -f
```

### Restart

```bash
kubectl rollout restart statefulset/technitium -n dns
```

### Force Zone Sync

```bash
# Restart the sync watcher to trigger immediate sync
kubectl rollout restart deployment/dns-sync-watcher -n dns
```

### Backup

Zone data is stored in PVCs. Use Velero for backup:

```bash
velero backup create technitium-backup --include-namespaces dns
```

## Failover Testing

```bash
# Test all DNS servers
for ip in 10.10.201.5 10.10.201.71 10.10.201.72 10.10.201.6 10.10.100.5; do
  echo -n "$ip: "
  dig @$ip google.com +short | head -1
done

# Test ad blocking
dig @10.10.201.5 ads.google.com  # Should return NXDOMAIN or 0.0.0.0
```

## Troubleshooting

### Zones Not Syncing

1. Check sync watcher logs:
   ```bash
   kubectl logs -n dns deployment/dns-sync-watcher
   ```

2. Manually trigger resync on a secondary:
   ```bash
   # Get token
   curl "http://10.10.201.72:5380/api/user/login?user=<user>&pass=<pass>"
   # Resync
   curl "http://10.10.201.72:5380/api/zones/resync?token=<token>&zone=wind.etherport.net"
   ```

3. Check zone transfer ACLs in primary web UI

### Pod Communication Issues

The K8s secondary (technitium-1) uses the primary's pod IP for zone transfers. If pods restart with new IPs, update the catalog zone's `primaryNameServerAddresses` on the secondary.

### Zone Transfer Failures / Expired Zones

If secondary zones show `isExpired: true` or `syncFailed: true`:

1. **Check dns-cluster zone records** on the primary:
   ```bash
   # Verify dns1.dns-cluster.wind.etherport.net has an A record
   dig @10.10.201.71 dns1.dns-cluster.wind.etherport.net
   # Should return 10.10.201.71 (technitium-0 VIP)
   ```

2. **If dns1 has no A record**, add it via API:
   ```bash
   # Login and add record
   TOKEN=$(curl -s "http://10.10.201.71:5380/api/user/login?user=<user>&pass=<pass>" | jq -r .token)
   curl "http://10.10.201.71:5380/api/zones/records/add?token=$TOKEN&zone=dns-cluster.wind.etherport.net&domain=dns1.dns-cluster.wind.etherport.net&type=A&ipAddress=10.10.201.71"
   ```

3. **Trigger resync** on all secondaries:
   ```bash
   for ip in 10.10.201.72 10.10.201.6 10.10.100.5; do
     TOKEN=$(curl -s "http://$ip:5380/api/user/login?user=<user>&pass=<pass>" | jq -r .token)
     curl "http://$ip:5380/api/zones/resync?token=$TOKEN&zone=wind.etherport.net"
   done
   ```

**Critical DNS Records (dns-cluster.wind.etherport.net zone):**

| Record | IP | Purpose |
|--------|-----|---------|
| dns1 | 10.10.201.71 | Primary DNS server VIP (technitium-0) |
| dns2 | 10.10.201.72 | Secondary in K8s (technitium-1) |
| dns-fallback | 10.10.201.6 | Local fallback VM |
| dns-aws | 10.10.100.5 | AWS remote failover |

> **Important**: The `dns-cluster.wind.etherport.net` zone is managed directly by Technitium (not GitOps) and is used for cluster coordination. The dns1 A record is critical - without it, secondaries cannot perform zone transfers.

### Belt-and-Suspenders: Direct Sync

The `dns-sync-watcher` deployment syncs records directly to ALL Technitium instances (not just the primary), bypassing zone transfer dependencies. This ensures records stay current even if zone transfers fail.

## External Monitoring

AWS Route53 health checks monitor critical endpoints from outside the infrastructure:
- Home Assistant, Grafana, Traefik, Plex, Kopia
- Alerts via SNS email when endpoints become unreachable
- Operates independently of homelab DNS/VPN

Configuration: `infra/terraform/aws/external-monitoring/`

## Files

| File | Purpose |
|------|---------|
| `00-namespace.yaml` | DNS namespace |
| `01-configmap.yaml` | Technitium configuration |
| `02-statefulset.yaml` | StatefulSet + headless service |
| `03-service.yaml` | Main LoadBalancer service (VIP 10.10.201.5) |
| `04-ingressroute.yaml` | Traefik ingress for web UI |
| `05-secret.sops.yaml` | SOPS-encrypted admin credentials |
| `06-cluster-services.yaml` | Per-pod LoadBalancers for clustering |
| `07-dns-sync.yaml` | GitOps zone sync watcher |
| `zones/*.yaml` | DNS zone definitions (GitOps managed) |
| `kustomization.yaml` | Kustomize configuration |
