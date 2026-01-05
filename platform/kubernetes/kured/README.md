# Kured - Kubernetes Reboot Daemon

Automated, safe node reboots for security updates.

## What Kured Does

1. **Watches** for `/var/run/reboot-required` on each node
2. **Coordinates** reboots to maintain cluster availability
3. **Drains** node before reboot (moves pods safely)
4. **Reboots** during configured maintenance window (2am-6am Pacific)
5. **Waits** for node to be healthy before proceeding to next node

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│ Unattended Upgrades (on each node)                      │
│ - Auto-installs security updates                         │
│ - Creates /var/run/reboot-required                      │
└────────────────┬────────────────────────────────────────┘
                 ↓
┌─────────────────────────────────────────────────────────┐
│ Kured DaemonSet (runs on each node)                     │
│ - Checks for reboot-required every 5 min                │
│ - Waits for maintenance window (2am-6am)                │
│ - Cordons node → Drains pods → Reboots                  │
└─────────────────────────────────────────────────────────┘
```

## Installation

### 1. Configure Unattended Upgrades (First)

Run Ansible playbook to configure all nodes:

```bash
cd ~/Projects/homelab-infra/infra/kubespray
./venv/bin/ansible-playbook \
  -i inventory/mycluster/hosts.yaml \
  ../platform/kubernetes/kured/configure-unattended-upgrades.yml
```

This installs and configures:
- `unattended-upgrades` - Auto-installs security patches
- `apt-listchanges` - Logs package changes
- Configured to NOT auto-reboot (Kured handles that)

**Verify:**
```bash
# SSH to a node
ssh k8s-w1

# Check unattended-upgrades status
sudo systemctl status unattended-upgrades

# View logs
sudo cat /var/log/unattended-upgrades/unattended-upgrades.log | tail -20

# Check if reboot is required
ls -la /var/run/reboot-required 2>/dev/null && echo "Reboot pending" || echo "No reboot needed"
```

### 2. Install Kured via Helm

```bash
# Add helm repo
helm repo add kubereboot https://kubereboot.github.io/charts
helm repo update

# Install Kured
helm install kured kubereboot/kured \
  --namespace kube-system \
  --values platform/kubernetes/kured/kured-values.yaml

# Verify deployment
kubectl get ds -n kube-system kured
kubectl get pods -n kube-system -l app.kubernetes.io/name=kured
```

Expected output:
```
NAME    DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
kured   4         4         4       4            4           <none>          1m
```

### 3. Verify Kured is Working

```bash
# Check Kured logs
kubectl logs -n kube-system -l app.kubernetes.io/name=kured --tail=50

# Should see:
# - "Reboot not required" (if no updates pending)
# - "Reboot required but outside time window" (if updates pending)
# - "Reboot required, proceeding to drain" (during maintenance window)

# Check which nodes need reboot
kubectl get nodes -o json | jq -r '.items[] | select(.metadata.annotations."kured.reboot.required" == "true") | .metadata.name'
```

## Configuration

All settings in `kured-values.yaml`:

| Setting | Value | Description |
|---------|-------|-------------|
| `period` | 5m | Check interval |
| `startTime` | 2:00 | Maintenance window start (Pacific) |
| `endTime` | 6:00 | Maintenance window end (Pacific) |
| `concurrency` | 1 | Only one node at a time |
| `timeZone` | America/Los_Angeles | PST/PDT |

## Monitoring

### Prometheus Metrics

Kured exports metrics on port 8080:

```bash
# Forward port
kubectl port-forward -n kube-system ds/kured 8080:8080

# View metrics
curl http://localhost:8080/metrics | grep kured_
```

**Key metrics:**
- `kured_reboot_required` - Number of nodes requiring reboot
- `kured_reboot_duration_seconds` - Time taken for last reboot

### Grafana Dashboard

Import Kured dashboard (ID: 16952) or create custom:

```
- Nodes requiring reboot (gauge)
- Reboot history (timeline)
- Time until next maintenance window
```

## Testing

### Simulate a Required Reboot

```bash
# SSH to a worker node
ssh k8s-w2

# Manually create reboot-required file
sudo touch /var/run/reboot-required
sudo systemctl restart kured

# Check Kured logs
kubectl logs -n kube-system -l app.kubernetes.io/name=kured -c kured | grep "reboot required"
```

Kured will:
1. Detect reboot required
2. Wait for maintenance window (2am-6am)
3. Cordon node
4. Drain pods (respecting PodDisruptionBudgets)
5. Reboot
6. Wait for node to be Ready
7. Uncordon node
8. Move to next node (if any)

### Force Immediate Reboot (Emergency)

If you need to force a reboot outside maintenance window:

```bash
# Annotate node for immediate reboot
kubectl annotate node k8s-w1 kured.reboot.immediate=true

# Kured will reboot the node on next check (within 5 min)
```

## Maintenance Window Management

### Change Maintenance Window

Edit `kured-values.yaml` and upgrade:

```bash
# Edit kured-values.yaml, change startTime/endTime

# Upgrade release
helm upgrade kured kubereboot/kured \
  --namespace kube-system \
  --values platform/kubernetes/kured/kured-values.yaml
```

### Disable Kured Temporarily

```bash
# Suspend Kured (prevents any reboots)
kubectl scale deployment kured -n kube-system --replicas=0

# Re-enable
kubectl scale deployment kured -n kube-system --replicas=1
```

## Troubleshooting

### Node Not Rebooting

**Check:**
1. Is `/var/run/reboot-required` present?
   ```bash
   ssh k8s-w1 "ls -la /var/run/reboot-required"
   ```

2. Is it within maintenance window?
   ```bash
   TZ=America/Los_Angeles date
   # Should be between 2:00am - 6:00am
   ```

3. Are pods draining successfully?
   ```bash
   kubectl get pods -A -o wide | grep k8s-w1
   # Should see pods in Terminating state
   ```

4. Check Kured logs:
   ```bash
   kubectl logs -n kube-system -l app.kubernetes.io/name=kured --tail=100
   ```

### Node Stuck in Drain

If pod won't drain:

```bash
# Check PodDisruptionBudgets
kubectl get pdb -A

# Force drain
kubectl drain k8s-w1 --ignore-daemonsets --delete-emptydir-data --force --grace-period=30
```

### Multiple Nodes Trying to Reboot

Check concurrency setting:
```bash
kubectl get deployment kured -n kube-system -o yaml | grep concurrency
# Should be 1
```

## Alerts

Add Prometheus alerts:

```yaml
groups:
  - name: kured
    rules:
      - alert: KuredRebootRequired
        expr: kured_reboot_required > 0
        for: 24h
        labels:
          severity: warning
        annotations:
          summary: "Nodes pending reboot for 24h"
          description: "{{ $value }} nodes require reboot"

      - alert: KuredRebootScheduled
        expr: kured_reboot_required > 0 and hour() >= 2 and hour() < 6
        labels:
          severity: info
        annotations:
          summary: "Node reboot in progress"
```

## Best Practices

1. ✅ **Always test on workers first** - Never reboot control-plane during high load
2. ✅ **Set PodDisruptionBudgets** - Ensure critical apps have PDBs to prevent drain failures
3. ✅ **Monitor maintenance windows** - Verify reboots complete successfully
4. ✅ **Stagger updates** - Don't update all nodes on same day if possible
5. ✅ **Keep audit log** - Track which nodes rebooted when

## Uninstall

```bash
# Remove Kured
helm uninstall kured -n kube-system

# Optionally remove unattended-upgrades from nodes
ansible k8s_cluster -i inventory/mycluster/hosts.yaml \
  -b -a "apt remove -y unattended-upgrades"
```

## References

- [Kured Documentation](https://kured.dev/)
- [Ubuntu Unattended Upgrades](https://help.ubuntu.com/community/AutomaticSecurityUpdates)
- [Kubernetes Safe Drain](https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/)
