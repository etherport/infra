# Node OS Update Strategy

## Current State
- **OS**: Ubuntu 24.04.3 LTS
- **Kernel**: 6.8.0-90-generic
- **Nodes**: 4 (1 control-plane, 3 workers)
- **Update Method**: Manual (no automation)

## Recommended Strategy: Kured + Unattended Upgrades

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ 1. Unattended Upgrades (OS-level)                          │
│    - Auto-installs security updates                         │
│    - Creates /var/run/reboot-required when needed          │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ 2. Kured (Kubernetes Reboot Daemon)                        │
│    - Watches for reboot-required                           │
│    - Coordinates safe reboots                              │
│    - Maintains cluster availability                        │
└─────────────────────────────────────────────────────────────┘
```

### Phase 1: Install Kured

```bash
# Add Kured helm repo
helm repo add kubereboot https://kubereboot.github.io/charts
helm repo update

# Install Kured
helm install kured kubereboot/kured \
  --namespace kube-system \
  --set configuration.period=5m \
  --set configuration.rebootDays='[su,mo,tu,we,th,fr,sa]' \
  --set configuration.startTime=2am \
  --set configuration.endTime=6am \
  --set configuration.timeZone=America/Los_Angeles \
  --set configuration.notifyUrl="" \  # Optional: Slack/Teams webhook
  --set tolerations[0].effect=NoSchedule \
  --set tolerations[0].key=node-role.kubernetes.io/control-plane
```

**What this does:**
- Runs as DaemonSet on all nodes
- Checks every 5 minutes for reboot-required
- Only reboots during 2am-6am window (Pacific)
- Reboots one node at a time (waits for previous to be healthy)
- Respects PodDisruptionBudgets

### Phase 2: Configure Unattended Upgrades

On each node (via Ansible or manually):

```bash
# Install unattended-upgrades
sudo apt install unattended-upgrades apt-listchanges -y

# Configure
sudo cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};

Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";  # Kured handles reboots
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
EOF

# Enable automatic updates
sudo cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

# Enable and start
sudo systemctl enable unattended-upgrades
sudo systemctl start unattended-upgrades
```

### Phase 3: Monitor Updates

**Check Kured Status:**
```bash
# View Kured logs
kubectl logs -n kube-system -l app.kubernetes.io/name=kured

# Check which nodes are waiting for reboot
kubectl get nodes -o json | jq -r '.items[] | select(.metadata.annotations."kured.reboot.required" == "true") | .metadata.name'

# Check reboot history
kubectl get events -n kube-system | grep kured
```

**Check Unattended Upgrades:**
```bash
# On each node
sudo cat /var/log/unattended-upgrades/unattended-upgrades.log
sudo cat /var/run/reboot-required 2>/dev/null && echo "Reboot pending" || echo "No reboot needed"
```

### Phase 4: Ansible Automation (Optional)

Create Ansible playbook to configure all nodes:

```yaml
# playbooks/node-updates.yml
---
- name: Configure automated OS updates
  hosts: k8s_cluster
  become: yes
  tasks:
    - name: Install unattended-upgrades
      apt:
        name:
          - unattended-upgrades
          - apt-listchanges
        state: present
        update_cache: yes

    - name: Configure unattended-upgrades
      copy:
        dest: /etc/apt/apt.conf.d/50unattended-upgrades
        content: |
          Unattended-Upgrade::Allowed-Origins {
              "${distro_id}:${distro_codename}-security";
          };
          Unattended-Upgrade::Automatic-Reboot "false";
          Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";

    - name: Enable auto-updates
      copy:
        dest: /etc/apt/apt.conf.d/20auto-upgrades
        content: |
          APT::Periodic::Update-Package-Lists "1";
          APT::Periodic::Unattended-Upgrade "1";

    - name: Start unattended-upgrades
      systemd:
        name: unattended-upgrades
        enabled: yes
        state: started
```

Run with:
```bash
cd ~/Projects/homelab-infra/kubespray
./venv/bin/ansible-playbook -i inventory/mycluster/hosts.yaml playbooks/node-updates.yml
```

## Alternative: Manual Update Runbook

If you prefer manual control:

### Monthly Maintenance Window

```bash
# 1. Check for updates on all nodes
for node in k8s-cp1 k8s-w1 k8s-w2 k8s-gpu1; do
  echo "=== $node ==="
  ssh $node "sudo apt update && apt list --upgradable"
done

# 2. Update one worker at a time
NODE=k8s-w1

# Cordon node (prevent new pods)
kubectl cordon $NODE

# Drain node (move workloads)
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data

# SSH and update
ssh $NODE "sudo apt update && sudo apt upgrade -y && sudo apt autoremove -y"

# Reboot if kernel updated
ssh $NODE "sudo reboot"

# Wait for node to come back (2-3 minutes)
kubectl wait --for=condition=Ready node/$NODE --timeout=300s

# Uncordon node
kubectl uncordon $NODE

# Repeat for next node
```

## Monitoring & Alerting

### Prometheus Alerts

```yaml
# alerts/node-updates.yaml
groups:
  - name: node-updates
    interval: 5m
    rules:
      - alert: NodeRebootRequired
        expr: node_reboot_required == 1
        for: 24h
        labels:
          severity: warning
        annotations:
          summary: "Node {{ $labels.node }} requires reboot"
          description: "Security updates installed, reboot pending for 24h"

      - alert: NodeKernelOutdated
        expr: (time() - node_boot_time_seconds) > (86400 * 30)
        labels:
          severity: info
        annotations:
          summary: "Node {{ $labels.node }} kernel is 30+ days old"
          description: "Consider updating kernel version"
```

### Grafana Dashboard

Create dashboard showing:
- Last update time per node
- Pending updates count
- Reboot status
- Kernel versions
- Uptime

## Best Practices

1. **Always update one node at a time** - Maintain cluster availability
2. **Use maintenance windows** - 2am-6am when traffic is low
3. **Test updates first** - Update workers before control-plane
4. **Monitor after reboot** - Ensure all pods are healthy
5. **Keep audit log** - Track what was updated and when
6. **PodDisruptionBudgets** - Ensure critical apps have PDBs
7. **Backup before major updates** - Snapshot VMs or use Velero

## Update Types

| Type | Frequency | Automation | Risk |
|------|-----------|------------|------|
| Security patches | Weekly | Automated (unattended-upgrades) | Low |
| Kernel updates | Monthly | Semi-automated (kured reboots) | Medium |
| Kubernetes version | Quarterly | Manual (kubespray) | High |
| OS version (24.04 → 24.10) | Yearly | Manual | High |

## Emergency Patch Process

For critical CVEs requiring immediate patching:

```bash
# 1. Identify affected nodes
# 2. Apply emergency patch
# 3. Force immediate reboot if needed

# Mark node for immediate reboot (bypass kured schedule)
kubectl annotate node k8s-w1 kured.reboot.immediate=true

# Or manually drain and reboot
kubectl drain k8s-w1 --ignore-daemonsets --delete-emptydir-data --force
ssh k8s-w1 "sudo apt update && sudo apt install -y <package> && sudo reboot"
```

## Rollback Strategy

If update causes issues:

```bash
# Option 1: Revert to previous kernel
ssh k8s-w1
sudo grub-reboot "Ubuntu, with Linux 6.8.0-89-generic"
sudo reboot

# Option 2: Restore from VM snapshot (if available)

# Option 3: Hold package version
ssh k8s-w1
sudo apt-mark hold <package>
```

## References

- [Kured Documentation](https://kured.dev/)
- [Ubuntu Unattended Upgrades](https://help.ubuntu.com/community/AutomaticSecurityUpdates)
- [Kubernetes Node Maintenance](https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/)
