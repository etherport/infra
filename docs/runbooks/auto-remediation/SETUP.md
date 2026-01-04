# Auto-Remediation System - Setup Guide

## Overview

Automatic service recovery system that detects failures and restarts services automatically.

## Architecture

```
Prometheus (detects issues)
    ↓
Alertmanager (routes alerts)
    ↓ (webhook)
Remediation Controller (takes action)
    ↓
Kubernetes API (restart pods)
```

## Deployment

### 1. Deploy Auto-Remediation System

```bash
kubectl apply -k platform/kubernetes/auto-remediation/
```

This creates:
- Namespace: `auto-remediation`
- ServiceAccount + RBAC
- ConfigMap with remediation rules
- Controller deployment
- Webhook service

### 2. Deploy Monitoring Alerts

```bash
kubectl apply -f platform/kubernetes/monitoring/comprehensive-alerts.yaml
kubectl apply -f platform/kubernetes/monitoring/dns-health-alerts.yaml
```

### 3. Update Alertmanager Configuration

The alertmanager configuration needs to route alerts to the remediation webhook.

Add these receivers and routes to your alertmanager config:

```yaml
receivers:
- name: "auto-remediation"
  webhook_configs:
  - url: 'http://remediation-webhook.auto-remediation.svc.cluster.local:8080'
    send_resolved: false

- name: "email-and-remediate"
  email_configs:
  - to: 'your-email@example.com'
    # ... email config ...
  webhook_configs:
  - url: 'http://remediation-webhook.auto-remediation.svc.cluster.local:8080'
    send_resolved: false

route:
  routes:
  # DNS Issues - Auto-remediate with email
  - matchers:
    - alertname =~ "NodeLocalDNS.*|CoreDNSDown"
    receiver: "email-and-remediate"
    group_wait: 30s
    repeat_interval: 15m

  # Other auto-remediate alerts
  - matchers:
    - auto_remediate = "true"
    receiver: "email-and-remediate"
    group_wait: 2m
    repeat_interval: 30m
```

Update the secret:
```bash
kubectl create secret generic alertmanager-monitoring-kube-prometheus-alertmanager \
  -n monitoring \
  --from-file=alertmanager.yaml=<your-config-file> \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Verification

### Check Controller Status
```bash
kubectl get all -n auto-remediation
kubectl logs -n auto-remediation -l app=remediation-controller
```

### Check Alerts
```bash
kubectl get prometheusrule -A | grep -E "comprehensive|dns-health"
```

### Test Alert Flow
Port forward to Prometheus and check alerts page:
```bash
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090
# Visit http://localhost:9090/alerts
```

## Adding New Services

### 1. Create PrometheusRule

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: myservice-alerts
  namespace: monitoring
spec:
  groups:
  - name: myservice
    rules:
    - alert: MyServiceDown
      expr: kube_deployment_status_replicas_available{namespace="mynamespace",deployment="myservice"} == 0
      for: 2m
      labels:
        severity: warning
        auto_remediate: "true"  # Important!
      annotations:
        summary: "My Service is down"
```

### 2. Add Remediation Rule

Edit the ConfigMap:
```bash
kubectl edit configmap -n auto-remediation remediation-rules
```

Add:
```yaml
MyServiceDown:
  action: restart_pods
  namespace: mynamespace
  selector: app=myservice
  description: "Restart My Service pods"
```

### 3. Reload Controller

```bash
kubectl delete pod -n auto-remediation -l app=remediation-controller
```

## Troubleshooting

### Controller Not Starting
```bash
kubectl describe pod -n auto-remediation -l app=remediation-controller
kubectl logs -n auto-remediation -l app=remediation-controller
```

### Alerts Not Firing
Check Prometheus:
```bash
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090
# Visit http://localhost:9090/alerts
```

### Actions Not Taken
1. Check controller logs
2. Verify alert has `auto_remediate: "true"` label
3. Check cooldown period (15 minutes between actions)
4. Verify alert name matches rule in ConfigMap

## Safety Features

- **15-minute cooldown**: Prevents restart loops
- **Email notifications**: You're always informed
- **Action logging**: Full audit trail
- **Selective**: Only acts on pre-defined alerts

## Disabling

Temporarily disable all auto-remediation:
```bash
kubectl scale deployment -n auto-remediation remediation-controller --replicas=0
```

Re-enable:
```bash
kubectl scale deployment -n auto-remediation remediation-controller --replicas=1
```
