# Auto-Remediation System Runbooks

Documentation for the automatic service recovery system.

## Quick Links

- **[Setup Guide](./SETUP.md)** - How to deploy and configure
- **[Coverage Status](./COVERAGE.md)** - What services are protected

## Overview

The auto-remediation system automatically detects and recovers from service failures:

1. **Prometheus** monitors services and fires alerts
2. **Alertmanager** routes alerts to the remediation webhook
3. **Remediation Controller** receives alerts and takes action
4. **Email notifications** inform you of all actions

## Key Features

- ✅ **Automatic recovery** for 22 different failure types
- ✅ **15-minute cooldown** prevents restart loops
- ✅ **Email notifications** for all actions
- ✅ **Full audit logging** of all remediation actions
- ✅ **100% coverage** of critical services

## Common Tasks

### View Recent Actions
```bash
kubectl logs -n auto-remediation -l app=remediation-controller --tail=50
```

### Add New Service
See [SETUP.md](./SETUP.md#adding-new-services)

### Temporarily Disable
```bash
kubectl scale deployment -n auto-remediation remediation-controller --replicas=0
```

### Update Rules
```bash
kubectl edit configmap -n auto-remediation remediation-rules
kubectl delete pod -n auto-remediation -l app=remediation-controller  # Reload
```

## Files

- `SETUP.md` - Deployment and configuration guide
- `COVERAGE.md` - Current protection coverage
- `README.md` - This file

## Source Code

Platform deployment: `platform/kubernetes/auto-remediation/`
