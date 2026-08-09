# Cloudflare Dynamic DNS Updater

Containerized dynamic DNS updater for Cloudflare. Keeps the configured
A records in sync with the homelab's current active-WAN public IP via
the Cloudflare API.

> **Migration note (2026-05-27):** this module was renamed from
> `route53-ddns` and rewritten to call the Cloudflare API (curl) instead
> of aws-cli + Route53; the image (`ghcr.io/etherport/cloudflare-ddns:main`)
> no longer bundles aws-cli. See
> `docs/runbooks/archive/cloudflare-ddns-migration.md` for the record.

**Deployment Method**: managed via **Flux GitOps**. Changes are
deployed automatically from git commits.

## Features

- Multi-record support — sync N record names within a single CF zone
- Active-WAN detection — picks wan1 vs wan2 by comparing egress IP
- Prometheus metrics via Pushgateway
- Kubernetes-native — runs as a CronJob every minute (concurrencyPolicy: Forbid)
- Minimal footprint — 64Mi requests / 128Mi limit
- Non-root, drops all capabilities

## Quick Start

### 1. Create the Cloudflare API token secret

The CronJob loads `CF_API_TOKEN` from a SOPS-encrypted Secret. Use the
template as a starting point:

```bash
cp base/cloudflare-credentials.sops.yaml.template \
   base/cloudflare-credentials.sops.yaml
# Edit, then encrypt in place
sops --encrypt --in-place base/cloudflare-credentials.sops.yaml
```

**Required Cloudflare token scopes** (create at
[Cloudflare → My Profile → API Tokens](https://dash.cloudflare.com/profile/api-tokens)):

| Scope | Permission | Resource |
|-------|------------|----------|
| Zone | DNS | Edit | The etherport.net zone (or whichever zone holds the records) |
| Zone | Zone | Read | Same zone |

### 2. Configure DNS records

Edit `base/configmap.yaml`:

```yaml
data:
  # Cloudflare zone ID for the target zone (see CF dashboard → zone overview → API section)
  cf_zone_id: "c45213cbf36fc634b6b75ae9abd49c59"

  # Comma-separated record names within that zone
  record_names: "wind.etherport.net,sip.wind.etherport.net"

  # DNS record TTL in seconds
  ttl: "300"

  # IP source: "auto" picks the currently-active WAN by comparing the
  # cluster's egress IP to wan1.wind.etherport.net / wan2.wind.etherport.net.
  ip_dns_source: "auto"
  ip_wan1_dns: "wan1.wind.etherport.net"
  ip_wan2_dns: "wan2.wind.etherport.net"

  # Fallback (only used if ip_dns_source != "auto")
  ip_service_url: "https://checkip.amazonaws.com"
```

### 3. Deploy

This module is managed by Flux. Commit changes to git; Flux reconciles
within ~10 minutes (or force it — no flux CLI on the hosts, CLAUDE.md §3):

```bash
git add platform/kubernetes/cloudflare-ddns/base/configmap.yaml
git commit -m "cloudflare-ddns: update DNS records"
git push
kubectl annotate -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
```

### 4. Monitor updates

```bash
# Schedule + last runs
kubectl get cronjob -n cloudflare-ddns cloudflare-ddns
kubectl get jobs -n cloudflare-ddns --sort-by=.metadata.creationTimestamp

# Latest logs
kubectl logs -n cloudflare-ddns -l app=cloudflare-ddns --tail=200
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `cf_zone_id` | *(required)* | Cloudflare zone ID containing the records |
| `record_names` | *(required)* | Comma-separated A-record names within the zone |
| `ttl` | `300` | DNS record TTL in seconds |
| `ip_dns_source` | `auto` | `auto` for active-WAN detection, or a specific DNS name |
| `ip_wan1_dns` | `wan1.wind.etherport.net` | First WAN reference for auto-detect |
| `ip_wan2_dns` | `wan2.wind.etherport.net` | Second WAN reference for auto-detect |
| `ip_service_url` | `https://checkip.amazonaws.com` | Fallback IP source when not in auto mode |

CronJob schedule defaults to `* * * * *` (every minute, for fast WAN
failover response). `concurrencyPolicy: Forbid` prevents overlapping runs.

## Prometheus Metrics

When the Pushgateway is reachable, the script exports:

| Metric | Type | Description |
|--------|------|-------------|
| `cloudflare_ddns_success` | Gauge | 1 if run succeeded, 0 if failed |
| `cloudflare_ddns_updates_made` | Gauge | Records that needed an update this run |
| `cloudflare_ddns_updates_skipped` | Gauge | Records already correct |
| `cloudflare_ddns_updates_failed` | Gauge | Records that failed to update |
| `cloudflare_ddns_duration_seconds` | Gauge | Run duration |
| `cloudflare_ddns_last_run_timestamp` | Gauge | Unix timestamp of last run |

Inspect:

```bash
curl -s http://pushgateway.monitoring.svc.cluster.local:9091/metrics \
  | grep cloudflare_ddns
```

## Troubleshooting

**Auth failure from CF API**
- Verify `CF_API_TOKEN` is present in the `cloudflare-credentials`
  Secret (`kubectl get secret -n cloudflare-ddns cloudflare-credentials -o yaml`)
- Token must have Zone DNS:Edit + Zone:Read on the target zone

**Record not updating**
- Confirm `cf_zone_id` matches the zone that holds the record
- Check `dig +short wind.etherport.net @1.1.1.1`
- Inspect job logs for `Existing IP` vs `New IP`

**Job not running**
- `kubectl get cronjob -n cloudflare-ddns` — confirm `SUSPEND=False`
- `kubectl get jobs -n cloudflare-ddns` — check recent run status

## Security

- Runs as non-root (UID 1000)
- Drops all Linux capabilities, seccomp RuntimeDefault
- CF API token scoped to a single zone (DNS edit only)
- Token stored in a SOPS-encrypted Kubernetes Secret

## References

- [Cloudflare DNS Records API](https://developers.cloudflare.com/api/operations/dns-records-for-a-zone-list-dns-records)
- [Kubernetes CronJobs](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/)
- Migration runbook: `docs/runbooks/archive/cloudflare-ddns-migration.md`
