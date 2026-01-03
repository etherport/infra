# Route53 Dynamic DNS Updater

Containerized dynamic DNS updater for AWS Route53. Automatically updates DNS A records with your current public IP address.

**Deployment Method**: This application is managed via **Flux GitOps**. Changes are deployed automatically from git commits.

## Features

- ✅ **Multi-domain support**: Update multiple DNS records across different hosted zones
- ✅ **IP change detection**: Only updates when public IP changes
- ✅ **Prometheus metrics**: Exports update statistics to Pushgateway
- ✅ **Kubernetes-native**: Runs as CronJob, configurable via ConfigMap
- ✅ **Minimal resources**: 64MB RAM, runs every 5 minutes
- ✅ **Secure**: Uses IAM credentials, runs as non-root user
- ✅ **GitOps managed**: Configuration changes via git commits (see [Flux Overview](../../docs/gitops/flux-overview.md))

## Quick Start

### 1. Create AWS Credentials Secret

```bash
kubectl create namespace route53-ddns

kubectl create secret generic route53-ddns-credentials \
  --namespace=route53-ddns \
  --from-literal=AWS_ACCESS_KEY_ID=<your-key-id> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<your-secret-key>
```

**Required IAM Permissions:**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "route53:ListResourceRecordSets",
        "route53:ChangeResourceRecordSets"
      ],
      "Resource": "arn:aws:route53:::hostedzone/*"
    }
  ]
}
```

### 2. Configure DNS Records

Edit `base/configmap.yaml`:

```yaml
data:
  # Your Route53 hosted zone IDs (comma-separated)
  hosted_zones: "Z10298356ZVPFVHAMFXP,Z03500581XDWV5SKF5PK8"

  # DNS record names to update (must match order of hosted_zones)
  record_names: "wind.gmsmeg.net,wind.etherport.net"

  # DNS TTL in seconds
  ttl: "300"

  # Service to fetch public IP from
  ip_service_url: "http://checkip.amazonaws.com"
```

**Important**:
- Number of `hosted_zones` must match number of `record_names`
- Order matters: first zone ID corresponds to first record name, etc.

### 3. Deploy to Kubernetes

#### GitOps Deployment (Recommended)

This application is managed by Flux. Configuration changes are made via git:

```bash
# Edit configuration (e.g., add/remove DNS records)
vim platform/kubernetes/route53-ddns/base/configmap.yaml

# Commit and push
git add platform/kubernetes/route53-ddns/base/configmap.yaml
git commit -m "route53-ddns: update DNS records"
git push

# Force Flux to sync immediately (or wait ~10 minutes)
flux reconcile source git flux-system
flux reconcile kustomization flux-system

# Verify CronJob is updated
kubectl get cronjob -n route53-ddns
kubectl describe cronjob route53-ddns -n route53-ddns

# Test immediately (don't wait for cron schedule)
kubectl create job --from=cronjob/route53-ddns route53-test-$(date +%s) -n route53-ddns
kubectl logs -n route53-ddns job/route53-test-<timestamp>
```

See [Making Changes to GitOps Apps](../../docs/gitops/making-changes.md) for detailed workflows.

#### Manual Deployment (Not Recommended)

If you need to bypass GitOps (changes will be reverted by Flux):

```bash
# Apply all resources
kubectl apply -k platform/kubernetes/route53-ddns/base

# Verify deployment
kubectl get cronjob -n route53-ddns
kubectl get pods -n route53-ddns
```

### 4. Monitor Updates

```bash
# Watch CronJob schedule
kubectl get cronjob -n route53-ddns route53-ddns

# View recent job runs
kubectl get jobs -n route53-ddns --sort-by=.metadata.creationTimestamp

# Check logs from latest run
kubectl logs -n route53-ddns -l job-name=$(kubectl get jobs -n route53-ddns -o name | tail -1 | cut -d'/' -f2)
```

## Configuration

### ConfigMap Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `hosted_zones` | *(required)* | Comma-separated Route53 hosted zone IDs |
| `record_names` | *(required)* | Comma-separated DNS record names |
| `ttl` | `300` | DNS record TTL in seconds |
| `ip_service_url` | `http://checkip.amazonaws.com` | URL to fetch public IP from |

### CronJob Schedule

Default: `*/5 * * * *` (every 5 minutes)

To change:
```bash
kubectl edit cronjob -n route53-ddns route53-ddns
# Modify spec.schedule
```

Common schedules:
- Every minute: `* * * * *`
- Every 5 minutes: `*/5 * * * *`
- Every 15 minutes: `*/15 * * * *`
- Hourly: `0 * * * *`

### Resource Limits

Default:
- **Requests**: 64MB RAM, 50m CPU
- **Limits**: 128MB RAM, 100m CPU

These are very conservative - the script typically uses <10MB RAM.

## How It Works

```
┌─────────────────────────────────────────────────┐
│ 1. Kubernetes CronJob triggers (every 5 min)   │
└────────────────┬────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────┐
│ 2. Fetch current public IP                     │
│    curl http://checkip.amazonaws.com            │
└────────────────┬────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────┐
│ 3. For each DNS record:                         │
│    - Get existing IP from Route53               │
│    - Compare with current IP                    │
│    - Update if different (UPSERT)               │
└────────────────┬────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────┐
│ 4. Push metrics to Prometheus (optional)       │
│    - Success/failure status                     │
│    - Number of updates made                     │
│    - Duration                                   │
└─────────────────────────────────────────────────┘
```

## Prometheus Metrics

If Prometheus Pushgateway is available, the following metrics are exported:

| Metric | Type | Description |
|--------|------|-------------|
| `route53_ddns_success` | Gauge | 1 if update succeeded, 0 if failed |
| `route53_ddns_updates_made` | Gauge | Number of DNS records updated |
| `route53_ddns_updates_skipped` | Gauge | Number of records skipped (no change) |
| `route53_ddns_updates_failed` | Gauge | Number of failed updates |
| `route53_ddns_duration_seconds` | Gauge | Duration of update process |
| `route53_ddns_last_run_timestamp` | Gauge | Unix timestamp of last run |

Access metrics:
```bash
curl http://pushgateway.monitoring.svc.cluster.local:9091/metrics | grep route53_ddns
```

## Troubleshooting

### Check Job Status

```bash
# List recent jobs
kubectl get jobs -n route53-ddns

# Get logs from failed job
kubectl logs -n route53-ddns job/route53-ddns-TIMESTAMP
```

### Common Issues

**1. "Could not determine current public IP"**
- Check internet connectivity from pod
- Verify IP service URL is accessible
- Try alternative: `https://api.ipify.org` or `https://ifconfig.me/ip`

**2. "AccessDenied" from Route53**
- Verify AWS credentials are correct
- Check IAM policy has required permissions
- Ensure hosted zone IDs are correct

**3. Job not running**
- Check CronJob: `kubectl get cronjob -n route53-ddns`
- Verify schedule is correct
- Check for failed jobs: `kubectl get jobs -n route53-ddns`

**4. Updates not persisting**
- Verify TTL is appropriate (300s = 5min)
- Check DNS propagation: `dig +short wind.gmsmeg.net`
- Ensure no conflicting DNS updates

### Manual Test Run

```bash
# Create a one-off test job
kubectl create job test-ddns -n route53-ddns \
  --from=cronjob/route53-ddns

# Watch logs
kubectl logs -n route53-ddns -f job/test-ddns
```

## Example Output

```
======================================
Route53 Dynamic DNS Updater
======================================
Time:        2026-01-02T04:50:00Z
Zones:       2
TTL:         300s
IP Service:  http://checkip.amazonaws.com
======================================

[1/3] Fetching current public IP...
Current public IP: 203.0.113.42

[2/3] Checking and updating DNS records...
---
Processing: wind.gmsmeg.net (zone: Z10298356ZVPFVHAMFXP)
Existing IP: 203.0.113.41
Status: Updated successfully (Change ID: C1234567890ABC)
Change: 203.0.113.41 → 203.0.113.42
---
Processing: wind.etherport.net (zone: Z03500581XDWV5SKF5PK8)
Existing IP: 203.0.113.42
Status: No change needed (already 203.0.113.42)

======================================
Summary
======================================
Public IP:       203.0.113.42
Records checked: 2
Updated:         1
Skipped:         1 (no change)
Failed:          0

Updated records:
  - wind.gmsmeg.net → 203.0.113.42
======================================

[3/3] Pushing metrics to Prometheus...
Metrics pushed successfully
Route53 DDNS update complete
```

## Security Considerations

- ✅ Runs as non-root user (UID 1000)
- ✅ Read-only root filesystem
- ✅ Drops all capabilities
- ✅ Uses seccomp RuntimeDefault profile
- ✅ AWS credentials stored in Kubernetes Secret
- ✅ Minimal IAM permissions (Route53 only)

## Alternatives

### Why not use external-dns?

[external-dns](https://github.com/kubernetes-sigs/external-dns) is great for managing DNS records for Kubernetes services/ingresses, but is overkill for simple dynamic DNS. This solution:

- ✅ Simpler: Single script, no complex CRDs
- ✅ Lightweight: 64MB vs 256MB+ for external-dns
- ✅ Purpose-built: Just updates your home IP, nothing more
- ✅ Lower cost: Runs every 5 min vs constant reconciliation

### Why not use ddclient?

[ddclient](https://ddclient.net/) supports many DDNS providers but:
- ❌ Not designed for containers/Kubernetes
- ❌ Complex configuration file format
- ❌ Perl dependencies
- ✅ This solution: Single bash script, AWS CLI only

## Cost

### AWS Route53 Pricing (US-West-2)

- **Hosted Zone**: $0.50/month per zone
- **Route53 API Requests**:
  - First 1 billion queries/month: $0.40 per million
  - `ListResourceRecordSets`: $0.40 per million
  - `ChangeResourceRecordSets`: $0.40 per million

### Monthly Cost Estimate

Running every 5 minutes with 2 DNS records:

```
Runs per month: 12 runs/hour × 24 hours × 30 days = 8,640 runs
API calls per run: 2 LIST + 0-2 CHANGE = ~2-4 calls
Total API calls: 8,640 × 3 (avg) = 25,920 calls

Cost: 25,920 / 1,000,000 × $0.40 = $0.01/month
```

**Total monthly cost: ~$0.01** (essentially free)

## Development

### Building Locally

```bash
cd platform/kubernetes/route53-ddns/image
docker build -t route53-ddns:test .
docker run --rm \
  -e AWS_ACCESS_KEY_ID=xxx \
  -e AWS_SECRET_ACCESS_KEY=xxx \
  -e HOSTED_ZONES=Z123... \
  -e RECORD_NAMES=test.example.com \
  route53-ddns:test
```

### Testing Script Changes

```bash
# Test script locally
export HOSTED_ZONES="Z123..."
export RECORD_NAMES="test.example.com"
export TTL=300
bash platform/kubernetes/route53-ddns/image/scripts/update-route53.sh
```

## License

MIT

## References

- [AWS Route53 API Documentation](https://docs.aws.amazon.com/Route53/latest/APIReference/)
- [AWS CLI Route53 Commands](https://docs.aws.amazon.com/cli/latest/reference/route53/)
- [Kubernetes CronJobs](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/)
