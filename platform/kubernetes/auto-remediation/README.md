# Auto-Remediation System

Automatic service recovery system for Kubernetes cluster.

## Overview

This system automatically detects and remediates common service failures by:
1. Monitoring services via Prometheus alerts
2. Receiving alert webhooks in the remediation controller
3. Taking predefined actions (restart pods, scale deployments)
4. Sending email notifications of all actions

## Components

- **Namespace**: `auto-remediation`
- **Controller**: Python webhook service that receives alerts and executes remediation
- **Service**: `remediation-webhook` (ClusterIP, port 8080)
- **ConfigMap**: `remediation-rules` (maps alerts to actions)
- **RBAC**: ServiceAccount + ClusterRole for pod/deployment management

## Files

- `namespace.yaml` - Namespace definition
- `rbac.yaml` - ServiceAccount, ClusterRole, ClusterRoleBinding
- `configmap.yaml` - Remediation rules (alert → action mapping)
- `deployment.yaml` - Remediation controller deployment
- `service.yaml` - Webhook service
- `controller.py` - Python controller source code
- `kustomization.yaml` - Kustomize configuration

## Deployment

```bash
# Deploy via kustomize
kubectl apply -k platform/kubernetes/auto-remediation/

# Or apply individually
kubectl apply -f platform/kubernetes/auto-remediation/namespace.yaml
kubectl apply -f platform/kubernetes/auto-remediation/rbac.yaml
kubectl apply -f platform/kubernetes/auto-remediation/configmap.yaml
kubectl apply -f platform/kubernetes/auto-remediation/deployment.yaml
kubectl apply -f platform/kubernetes/auto-remediation/service.yaml
```

## Management

### View Logs
```bash
kubectl logs -n auto-remediation -l app=remediation-controller --tail=50
```

### Update Rules
```bash
kubectl edit configmap -n auto-remediation remediation-rules
kubectl delete pod -n auto-remediation -l app=remediation-controller  # Reload
```

### Disable Temporarily
```bash
kubectl scale deployment -n auto-remediation remediation-controller --replicas=0
```

## Safety Features

- **15-minute cooldown**: Prevents restart loops
- **Email notifications**: All actions notify graham.m.smith@me.com
- **Audit logging**: All actions logged to stdout
- **Selective activation**: Only alerts with `auto_remediate: "true"` trigger actions

## Alertmanager Integration

See `../monitoring/alertmanager-config.yaml` for webhook configuration.

Alerts route to two receivers:
- `email-alerts` - Email notification
- `auto-remediation` - Webhook to this service

## Documentation

- Setup guide: `docs/runbooks/auto-remediation/SETUP.md`
- Coverage status: `docs/runbooks/auto-remediation/COVERAGE.md`
