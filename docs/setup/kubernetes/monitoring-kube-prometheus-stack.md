# Monitoring (kube-prometheus-stack)

## Overview

The monitoring stack is deployed via Flux GitOps using the kube-prometheus-stack Helm chart. It provides:

- **Prometheus**: Metrics collection and storage
- **Alertmanager**: Alert routing and notifications (email via AWS SES)
- **Grafana**: Dashboards and visualization

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Flux GitOps                               │
│  clusters/wind/helm-releases/monitoring.yaml                    │
└─────────────────────┬───────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│               kube-prometheus-stack HelmRelease                  │
├─────────────────┬─────────────────┬─────────────────────────────┤
│   Prometheus    │   Alertmanager   │         Grafana            │
│   (metrics)     │   (notifications)│       (dashboards)         │
└────────┬────────┴────────┬─────────┴─────────────────────────────┘
         │                 │
         │                 ▼
         │      ┌──────────────────────┐
         │      │  AlertmanagerConfig  │
         │      │  (email-notifications)│
         │      └──────────┬───────────┘
         │                 │
         │                 ▼
         │      ┌──────────────────────┐
         │      │     AWS SES SMTP     │
         │      │  (email delivery)    │
         │      └──────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────────────┐
│                    PrometheusRule CRDs                          │
│  - comprehensive-alerts.yaml (GPU, services, pod health)        │
│  - external-alerts.yaml (external-host node-exporter alerts,     │
│       external-nodes job)                                        │
│  - dns-health-alerts.yaml                                       │
└─────────────────────────────────────────────────────────────────┘
```

## File Locations

| File | Purpose |
|------|---------|
| `clusters/wind/helm-releases/monitoring.yaml` | Flux HelmRelease with chart values |
| `platform/kubernetes/monitoring/03-alertmanager-config.yaml` | AlertmanagerConfig CR for email routing |
| `platform/kubernetes/monitoring/alertmanager-secret.sops.yaml` | SMTP credentials (SOPS encrypted) |
| `platform/kubernetes/monitoring/comprehensive-alerts.yaml` | Service and GPU monitoring alerts |
| `platform/kubernetes/monitoring/02-external-alerts.yaml` | External-host node-exporter alerts (external-nodes job) |
| `platform/kubernetes/monitoring/kustomization.yaml` | Kustomize config for monitoring resources |

## Deployment

Monitoring is deployed automatically via Flux GitOps. Manual changes should be made via git commits.

### Force Reconciliation

```bash
# Reconcile the HelmRelease
kubectl annotate --overwrite -n flux-system helmrelease/monitoring reconcile.fluxcd.io/requestedAt="$(date +%s)"

# Reconcile additional monitoring resources
kubectl annotate --overwrite -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
```

### Verify Installation

```bash
# Check pods
kubectl get pods -n monitoring

# Check HelmRelease status
kubectl get helmrelease monitoring -n flux-system

# Check Alertmanager config
kubectl get alertmanagerconfig -n monitoring
```

## Email Notifications

### Configuration

Email alerts are configured via AlertmanagerConfig CR and sent through AWS SES:

- **From**: alertmanager@wind.etherport.net
- **To**: graham.m.smith@me.com
- **SMTP**: email-smtp.us-west-2.amazonaws.com:587

### Alert Routing

| Severity | Behavior |
|----------|----------|
| `critical` | Email immediately, repeat every 1 hour |
| `warning` | Email after 30s group wait, repeat every 4 hours |
| `Watchdog` | Silenced (canary alert) |

### SMTP Credentials

SMTP credentials are stored in a SOPS-encrypted secret:

```bash
# View decrypted secret
sops -d platform/kubernetes/monitoring/alertmanager-secret.sops.yaml

# Edit secret
sops platform/kubernetes/monitoring/alertmanager-secret.sops.yaml
```

The IAM user `alertmanager-ses-smtp` provides SES SMTP access.

## Custom Alerts

### Alert Groups

| Group | Description |
|-------|-------------|
| `home-automation` | Home Assistant availability |
| `monitoring` | Grafana, Prometheus, Alertmanager health |
| `traefik` | Ingress controller health |
| `gpu-workloads` | Plex, Ollama, GPU workload crash detection |
| `gpu-operator` | NVIDIA driver and device plugin health |
| `pod-health` | Generic pod crash/OOM detection |

### GPU-Specific Alerts

After GPU driver updates, these alerts detect failures:

| Alert | Description |
|-------|-------------|
| `GPUWorkloadFailedAfterDriverUpdate` | Critical - GPU workload down within 30min of driver update |
| `GPUWorkloadCrashLooping` | Warning - Plex/Ollama restarting frequently |
| `GPUDriverDaemonsetNotReady` | Critical - Driver not running for 10min |
| `GPUDevicePluginNotReady` | Critical - Device plugin not running |

### Adding New Alerts

1. Edit `platform/kubernetes/monitoring/comprehensive-alerts.yaml`
2. Add PrometheusRule spec following existing patterns
3. Commit and push
4. Flux will automatically deploy

Example:
```yaml
- alert: MyServiceDown
  expr: kube_deployment_status_replicas_available{namespace="myns",deployment="myapp"} == 0
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "MyService is down"
    description: "MyService has no available replicas"
```

## Grafana

### Access

- **URL**: https://grafana.wind.etherport.net
- **Credentials**: See `platform/kubernetes/monitoring/grafana-admin-secret.sops.yaml`

### Dashboard Auto-Discovery

Grafana automatically discovers dashboards with these labels:
```yaml
labels:
  grafana_dashboard: "1"
```

Dashboards are searched across all namespaces (`searchNamespace: ALL`).

## Troubleshooting

### Check Alertmanager Status

```bash
# Get active alerts
kubectl exec -n monitoring alertmanager-monitoring-kube-prometheus-alertmanager-0 \
  -c alertmanager -- wget -q -O- http://localhost:9093/api/v2/alerts | python3 -m json.tool

# Check notification metrics
kubectl exec -n monitoring alertmanager-monitoring-kube-prometheus-alertmanager-0 \
  -c alertmanager -- wget -q -O- http://localhost:9093/metrics | grep alertmanager_notification
```

### Test Email Notifications

```bash
# Send test alert
kubectl exec -n monitoring alertmanager-monitoring-kube-prometheus-alertmanager-0 \
  -c alertmanager -- wget -q -O- \
  --header='Content-Type: application/json' \
  --post-data='[{"labels":{"alertname":"TestAlert","severity":"warning","namespace":"monitoring"},"annotations":{"summary":"Test alert"}}]' \
  http://localhost:9093/api/v2/alerts
```

### Common Issues

**Alerts not firing:**
- Check PrometheusRule is loaded: `kubectl get prometheusrule -n monitoring`
- Verify expression in Prometheus UI

**Emails not sending:**
- Check Alertmanager logs: `kubectl logs -n monitoring alertmanager-monitoring-kube-prometheus-alertmanager-0 -c alertmanager`
- Verify SMTP secret exists: `kubectl get secret alertmanager-smtp-config -n monitoring`
- Check SES sending stats: `aws ses get-send-statistics --profile homelab`

**AlertmanagerConfig not applied:**
- Verify label matches: `alertmanagerConfig: main`
- Check namespace selector in HelmRelease
- Restart Alertmanager: `kubectl rollout restart statefulset -n monitoring alertmanager-monitoring-kube-prometheus-alertmanager`

## Related Documentation

- [Operations Guide](../../runbooks/operations-guide.md)
- [AWS Infrastructure](../../architecture/aws-infrastructure.md)
- [IAM Policies](../../../infra/terraform/aws/iam-policies/README.md)
