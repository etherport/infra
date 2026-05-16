# Auto-Remediation Coverage Status

**Last Updated**: 2026-05-16
**Total alert rules in `comprehensive-alerts.yaml`**: 25
**Alerts with `auto_remediate: "true"`**: 16
**Coverage**: 100% of critical user-facing services; **gaps** below for
recent additions.

## Known gaps (not yet wired to auto-remediation)

Added since the original audit and currently alert-only — manual
intervention or follow-up needed if they fire:

- **CNPG cluster health** (`postgres-cluster` in `postgres` ns): cluster
  phase, replica lag, primary failover events. Operator handles failover
  itself; auto-remediation should focus on stuck rolling updates.
- **Barman continuous archiving** (`postgres` ns): WAL archive failures
  and lag on the `postgres-barman.wind.etherport.net` S3 bucket. See
  `docs/runbooks/postgres-barman.md`.
- **GPU operator** (`gpu-operator-system`): driver daemonset readiness,
  device-plugin advertisement on `k8s-gpu1`.
- **cert-manager** (`cert-manager`): wildcard certificate renewal /
  ClusterIssuer challenge failures (we have Down/webhook alerts but no
  cert-expiry remediation).
- **Velero schedule failures**: backup phase `Failed` /
  `PartiallyFailed` with no `PodVolumeBackup` data. Listed in the
  schedules under `platform/kubernetes/backups/velero/schedules/`.

Re-audit the rule set whenever a new HelmRelease is added to
`clusters/wind/helm-releases/`.

## Services Covered

### DNS Services (4 alerts)
- ✅ NodeLocalDNS (kube-system)
- ✅ CoreDNS (kube-system)  
- ✅ Technitium DNS (dns namespace)

### Home Automation (2 alerts)
- ✅ Home Assistant (home-automation)

### Monitoring Stack (3 alerts)
- ✅ Grafana (monitoring)
- ✅ Prometheus (monitoring)
- ✅ Alertmanager (monitoring)

### Ingress & Load Balancing (2 alerts)
- ✅ Traefik (traefik) - CRITICAL
- ✅ MetalLB Controller (metallb-system) - CRITICAL

### Certificate Management (2 alerts)
- ✅ Cert-Manager Controller (cert-manager)
- ✅ Cert-Manager Webhook (cert-manager)

### GitOps / Flux (3 alerts)
- ✅ Flux Helm Controller (flux-system)
- ✅ Flux Kustomize Controller (flux-system)
- ✅ Flux Source Controller (flux-system)

### Backup Services (2 alerts)
- ✅ Kopia (backups)
- ✅ Velero (velero)

### Media Services (1 alert)
- ✅ Plex (plex)

### Generic Pod Health (3 alerts)
- ✅ Pod Crash Looping (any namespace)
- ✅ Pod OOM Killed (any namespace)
- ✅ Pod Not Ready (any namespace)

## Alert Details

| Alert Name | Namespace | Trigger | Wait | Action |
|------------|-----------|---------|------|--------|
| NodeLocalDNSHighErrorRate | kube-system | SERVFAIL > 5% | 2m | Restart pods |
| NodeLocalDNSTimeout | kube-system | Timeouts detected | 2m | Restart pods |
| CoreDNSDown | kube-system | No replicas | 2m | Restart pods |
| TechnitiumDNSDown | dns | < 2 replicas | 3m | Restart pods |
| HomeAssistantDown | home-automation | No replicas | 2m | Restart pods |
| HomeAssistantPodCrashLooping | home-automation | Frequent restarts | 5m | Scale deployment |
| GrafanaDown | monitoring | No replicas | 2m | Restart pods |
| PrometheusDown | monitoring | No replicas | 2m | Restart pods |
| AlertmanagerDown | monitoring | No replicas | 2m | Restart pods |
| TraefikDown | traefik | No replicas | 2m | Restart pods |
| CertManagerDown | cert-manager | No replicas | 3m | Restart pods |
| CertManagerWebhookDown | cert-manager | No replicas | 3m | Restart pods |
| FluxHelmControllerDown | flux-system | No replicas | 3m | Restart pods |
| FluxKustomizeControllerDown | flux-system | No replicas | 3m | Restart pods |
| FluxSourceControllerDown | flux-system | No replicas | 3m | Restart pods |
| KopiaDown | backups | No replicas | 5m | Restart pods |
| VeleroDown | velero | No replicas | 5m | Restart pods |
| MetalLBControllerDown | metallb-system | No replicas | 3m | Restart pods |
| PlexDown | plex | No replicas | 5m | Restart pods |
| PodCrashLooping | any | Frequent restarts | 5m | Scale deployment |
| PodOOMKilled | any | OOM kill | 1m | Restart pods |
| PodNotReady | any | Not ready 10m | 10m | Restart pods |

## Expected Impact

### Before Auto-Remediation
- Detection: Manual (30min - 2hr)
- Resolution: Manual kubectl restart
- Total downtime: 30min - 2hr

### After Auto-Remediation
- Detection: Automatic (2-5min)
- Resolution: Automatic restart
- Total downtime: 2-5min

**Estimated Impact**: 90% reduction in manual interventions, 75% reduction in downtime

## Limitations

### What It Can Fix
- ✅ Pod crashes and restarts
- ✅ Service deployments going down
- ✅ Transient failures
- ✅ OOM killed pods
- ✅ Crash loops

### What It Cannot Fix
- ❌ Infrastructure failures (nodes down, disk full)
- ❌ Configuration errors (bad YAML, missing secrets)
- ❌ Network issues (switch failures)
- ❌ Persistent application bugs
- ❌ Resource exhaustion (cluster-wide)

## Monitoring

View auto-remediation actions:
```bash
kubectl logs -n auto-remediation -l app=remediation-controller --tail=50 -f
```

View active alerts:
```bash
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090
# Visit http://localhost:9090/alerts
```
