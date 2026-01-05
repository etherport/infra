# DNS Resolution Issues - Troubleshooting Guide

## Issue: Home Assistant Name Resolution Failures

**Date**: January 4, 2026  
**Status**: ✅ RESOLVED

### Symptoms
- Home Assistant unable to control certain devices
- Error message: "name resolution failed"
- DNS timeouts in cluster

### Root Cause

TCP/UDP protocol mismatch between NodeLocalDNS and CoreDNS:
- NodeLocalDNS configured with `force_tcp`
- CoreDNS configured with `prefer_udp`
- Stale TCP connections accumulated over 40+ hours
- Connections timing out on protocol mismatch

### Solution Applied

1. **Changed NodeLocalDNS configuration**
   - File: `platform/kubernetes/monitoring/nodelocaldns-udp-fix.yaml`
   - Changed all forwarding blocks from `force_tcp` to `prefer_udp`
   - Applied: `kubectl apply -f platform/kubernetes/monitoring/nodelocaldns-udp-fix.yaml`

2. **Restarted all NodeLocalDNS pods**
   - Command: `kubectl delete pod -n kube-system -l k8s-app=node-local-dns`
   - Result: Fresh connections with UDP protocol

3. **Added monitoring**
   - File: `platform/kubernetes/monitoring/dns-health-alerts.yaml`
   - Alerts: NodeLocalDNSHighErrorRate, NodeLocalDNSTimeout, CoreDNSDown
   - Auto-remediation: Automatic restart on detection

### Prevention

Auto-remediation system now monitors and automatically restarts DNS components:
- **NodeLocalDNSHighErrorRate**: Triggers when SERVFAIL > 5% for 2 minutes
- **NodeLocalDNSTimeout**: Triggers when forwarding timeouts detected
- **CoreDNSDown**: Triggers when CoreDNS pods unavailable

See: `docs/runbooks/auto-remediation/COVERAGE.md`

### Verification

```bash
# Check NodeLocalDNS configuration
kubectl get configmap -n kube-system nodelocaldns -o yaml | grep -A 3 "forward"

# Check pod status
kubectl get pods -n kube-system -l k8s-app=node-local-dns

# Check DNS from a pod
kubectl run test-dns --rm -i --restart=Never --image=busybox -- nslookup google.com
```

### Related Issues

This same root cause may affect:
- Multus multi-NIC pods (like Home Assistant with 4 interfaces)
- Services with complex networking requirements
- Long-running pods with persistent DNS connections

### Future Improvements

1. Consider NodeLocalDNS DaemonSet automatic rolling restarts (weekly)
2. Monitor for other TCP/UDP mismatches in network stack
3. Add metrics for connection age/staleness

## Related Documentation

- [Auto-Remediation System](auto-remediation/README.md)
- [Kubernetes Operations](kubernetes-ops.md)
- [Network Architecture](../architecture/network.md)
