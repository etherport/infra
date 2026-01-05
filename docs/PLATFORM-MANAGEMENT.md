# Platform Management Guide

Centralized documentation for reporting, monitoring, updates, and management across the entire homelab infrastructure.

## Platform Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Homelab Infrastructure                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    Kubernetes Cluster (K8s)                          │   │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐       │   │
│  │  │ k8s-cp1 │ │ k8s-w1  │ │ k8s-w2  │ │ k8s-w3  │ │ k8s-gpu1│       │   │
│  │  │ control │ │ worker  │ │ worker  │ │ worker  │ │ GPU     │       │   │
│  │  └─────────┘ └─────────┘ └─────────┘ └─────────┘ └─────────┘       │   │
│  │                                                                     │   │
│  │  Updates: Kured + unattended-upgrades (coordinated reboots)        │   │
│  │  Apps: Flux GitOps + Helm                                          │   │
│  │  Monitoring: Prometheus node-exporter DaemonSet                    │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    Standalone VMs (Non-K8s)                          │   │
│  │  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐   │   │
│  │  │dns-fallback │ │ vpn-local   │ │  dns-aws    │ │  vpn-aws    │   │   │
│  │  │ 10.10.201.6 │ │10.10.201.15 │ │ 10.10.100.5 │ │10.10.100.10 │   │   │
│  │  │ Technitium  │ │ WireGuard   │ │ Technitium  │ │ WireGuard   │   │   │
│  │  └─────────────┘ └─────────────┘ └─────────────┘ └─────────────┘   │   │
│  │                                                                     │   │
│  │  Updates: unattended-upgrades (staggered auto-reboot)              │   │
│  │  Config: Ansible playbooks                                         │   │
│  │  Monitoring: Prometheus node_exporter (standalone)                 │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 1. Monitoring & Reporting

### Access Points

| Service | URL | Purpose |
|---------|-----|---------|
| Grafana | https://grafana.wind.etherport.net | Dashboards, visualization |
| Prometheus | Internal (port-forward 9090) | Metrics, alerting |
| Alertmanager | Internal (port-forward 9093) | Alert routing |
| Technitium DNS | https://dns.wind.etherport.net:5380 | DNS management |

### Metrics Collection

| Component | Collector | Scrape Interval | Metrics |
|-----------|-----------|-----------------|---------|
| K8s nodes | node-exporter DaemonSet | 30s | CPU, memory, disk, network |
| K8s pods | kube-state-metrics | 30s | Pod status, resource requests |
| K8s API | Prometheus built-in | 30s | API latency, request counts |
| Standalone VMs | node_exporter (port 9100) | 30s | CPU, memory, disk, systemd |

### Active Alerts

**External Hosts (dns-fallback, vpn-local, dns-aws, vpn-aws):**

| Alert | Severity | Trigger |
|-------|----------|---------|
| ExternalHostDown | critical | Unreachable >2min |
| TechnitiumDNSDown | critical | DNS host down >1min |
| VPNGatewayDown | critical | VPN host down >2min |
| ExternalHostHighCPU | warning | CPU >80% for 10min |
| ExternalHostHighMemory | warning | Memory >85% for 5min |
| ExternalHostLowDisk | warning | Disk >80% full |
| ExternalHostCriticalDisk | critical | Disk >95% full |
| ExternalHostSystemdFailed | warning | Systemd unit failed |
| ExternalHostRebooted | info | Rebooted <10min ago |

**Kubernetes Cluster:**
- Standard kube-prometheus-stack alerts (KubePodCrashLooping, NodeNotReady, etc.)
- See: `kubectl get prometheusrules -A`

### Quick Health Checks

```bash
# === Kubernetes Cluster ===
kubectl get nodes -o wide
kubectl get pods -A | grep -v Running | grep -v Completed
flux get all -A

# === External Hosts ===
for host in 10.10.201.6 10.10.201.15 10.10.100.5 10.10.100.10; do
  echo -n "$host: "
  curl -s --connect-timeout 2 "http://$host:9100/metrics" | grep -c "^node_" || echo "DOWN"
done

# === DNS Cluster ===
dig @10.10.201.5 google.com +short

# === VPN Status ===
ssh graham@10.10.201.15 "sudo wg show"
```

---

## 2. Update Management

### Update Strategy by Component

| Component | Method | Frequency | Automation Level |
|-----------|--------|-----------|------------------|
| K8s node OS | Kured + unattended-upgrades | Daily (security) | Fully automated |
| K8s node kernel | Kured reboot | When needed | Automated reboot |
| Kubernetes version | Kubespray | Quarterly | Manual |
| Standalone VM OS | unattended-upgrades | Daily (security) | Fully automated |
| Standalone VM kernel | Auto-reboot (staggered) | When needed | Automated |
| Container images | Flux (some) / Manual | Varies | Semi-automated |
| Helm charts | Manual upgrade | Monthly | Manual |

### Automatic Reboot Schedule (Standalone VMs)

| Host | Reboot Window | Rationale |
|------|---------------|-----------|
| dns-fallback | 02:00 | DNS first, quick recovery |
| dns-aws | 02:30 | Staggered from local DNS |
| vpn-local | 03:00 | After DNS is back |
| vpn-aws | 03:30 | After local VPN is back |

### Kubernetes Node Updates (Kured)

Kured handles K8s node reboots:
- Checks for `/var/run/reboot-required` every 5 minutes
- Reboots one node at a time during maintenance window (2am-6am)
- Respects PodDisruptionBudgets
- Cordons/drains node before reboot

```bash
# Check Kured status
kubectl logs -n kube-system -l app.kubernetes.io/name=kured --tail=50

# Check nodes needing reboot
kubectl get nodes -o json | jq -r '.items[] | select(.metadata.annotations."kured.reboot.required" == "true") | .metadata.name'

# Force immediate reboot (emergency only)
kubectl annotate node k8s-w1 kured.reboot.immediate=true
```

### Manual Update Procedures

**Standalone VMs (Ansible):**
```bash
cd ~/Projects/homelab-infra/infra/ansible

# Check for updates (dry-run)
ansible all -i inventory/wind/ -i inventory/aws/ -m shell -a "apt list --upgradable 2>/dev/null | head -10"

# Apply base configuration + updates
ansible-playbook -i inventory/wind/ -i inventory/aws/ playbooks/base.yml
```

**Helm Charts:**
```bash
# Check for updates
helm repo update

# List installed releases
helm list -A

# Upgrade a release
helm upgrade monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring -f platform/kubernetes/monitoring/values.yaml
```

**Kubernetes Version (Major):**
See: `docs/NODE-UPDATES.md` for full procedure.

---

## 3. Application Deployment

### Deployment Methods

| Method | Use Case | Automation | Rollback |
|--------|----------|------------|----------|
| **Flux GitOps** | Apps in `platform/kubernetes/` | Push to git → auto-deploy | `git revert` |
| **Helm (manual)** | Complex charts (Prometheus, Velero) | `helm upgrade` | `helm rollback` |
| **Ansible** | Non-K8s host configuration | `ansible-playbook` | Re-run with previous values |

### Flux-Managed Applications

```bash
# List Flux-managed apps
flux get kustomizations -A

# Force sync after git push
flux reconcile source git flux-system
flux reconcile kustomization flux-system

# Suspend during maintenance
flux suspend kustomization flux-system
# ... make changes ...
flux resume kustomization flux-system
```

**Adding new app to Flux:**
1. Create manifests in `platform/kubernetes/<app-name>/`
2. Add `kustomization.yaml`
3. Reference in `clusters/wind/kustomization.yaml`
4. Commit and push
5. `flux reconcile kustomization flux-system`

### Helm-Managed Applications

| Release | Namespace | Chart | Values Location |
|---------|-----------|-------|-----------------|
| monitoring | monitoring | kube-prometheus-stack | `platform/kubernetes/monitoring/values.yaml` |
| kured | kube-system | kubereboot/kured | CLI flags |
| velero | velero | vmware-tanzu/velero | CLI flags |

```bash
# Upgrade helm release
helm upgrade <release> <chart> -n <namespace> -f values.yaml

# Rollback
helm rollback <release> <revision> -n <namespace>

# View history
helm history <release> -n <namespace>
```

### Container Image Updates

**For Flux-managed apps:**
1. Edit the image tag in the deployment YAML
2. Commit and push
3. Flux auto-deploys

**Future: Flux Image Automation** (not yet configured)
- Can automatically update image tags when new versions are pushed
- See: https://fluxcd.io/flux/guides/image-update/

---

## 4. Configuration Management

### Tools by Platform

| Platform | Tool | Config Location |
|----------|------|-----------------|
| Kubernetes apps | Flux/Kustomize | `platform/kubernetes/` |
| K8s cluster | Kubespray | `infra/kubespray/inventory/` |
| Standalone VMs | Ansible | `infra/ansible/` |
| Proxmox VMs | Terraform | `infra/terraform/proxmox/` |
| Secrets | SOPS + age | `*.sops.yaml` files |

### Ansible Playbooks

| Playbook | Purpose | Hosts |
|----------|---------|-------|
| `base.yml` | OS config, NTP, updates, monitoring | All non-K8s |
| `wireguard.yml` | VPN configuration | vpn_servers |
| `technitium.yml` | DNS server setup | dns_servers |

```bash
cd ~/Projects/homelab-infra/infra/ansible

# Run playbook
ansible-playbook -i inventory/wind/ -i inventory/aws/ playbooks/base.yml

# Dry-run
ansible-playbook -i inventory/wind/ playbooks/base.yml --check --diff

# Target specific hosts
ansible-playbook -i inventory/wind/ playbooks/base.yml --limit dns-fallback
```

### Secret Management

```bash
# Decrypt and view
sops -d platform/kubernetes/app/secret.sops.yaml

# Edit in place
sops platform/kubernetes/app/secret.sops.yaml

# Encrypt new file
sops -e secret.yaml > secret.sops.yaml
```

---

## 5. Backup & Recovery

### Backup Coverage

| Component | Backup Method | Frequency | Retention |
|-----------|---------------|-----------|-----------|
| K8s workloads | Velero | Daily | 30 days |
| K8s PVCs | Velero + Restic | Daily | 30 days |
| Proxmox VMs | Proxmox Backup | Weekly | 4 weeks |
| Git repo | GitHub | Every push | Infinite |
| DNS zones | Technitium cluster sync | Real-time | N/A |

### Velero Commands

```bash
# Check backup status
velero backup get

# Create manual backup
velero backup create manual-backup-$(date +%Y%m%d)

# Restore
velero restore create --from-backup <backup-name>

# Schedule status
velero schedule get
```

---

## 6. Troubleshooting Quick Reference

### Kubernetes Issues

```bash
# Pods not starting
kubectl describe pod <pod> -n <ns>
kubectl logs <pod> -n <ns> --previous

# Node issues
kubectl describe node <node>
kubectl get events --field-selector involvedObject.name=<node>

# Flux not syncing
flux logs --all-namespaces
kubectl describe kustomization flux-system -n flux-system
```

### Standalone VM Issues

```bash
# SSH to host
ssh graham@10.10.201.6

# Check services
systemctl status technitium
systemctl status node_exporter
journalctl -u technitium -f

# Check updates
cat /var/log/unattended-upgrades/unattended-upgrades.log
cat /var/run/reboot-required 2>/dev/null && echo "Reboot pending"
```

### Network/DNS Issues

```bash
# Test DNS
dig @10.10.201.5 google.com
dig @10.10.201.6 google.com

# Test VPN
ping 10.255.255.1  # AWS tunnel endpoint
ping 10.10.100.5   # AWS DNS (via VPN)

# Check WireGuard
ssh graham@10.10.201.15 "sudo wg show"
```

---

## 7. Runbook Links

| Topic | Document |
|-------|----------|
| Operations guide (commands) | [runbooks/operations-guide.md](runbooks/operations-guide.md) |
| Kubernetes ops | [runbooks/kubernetes-ops.md](runbooks/kubernetes-ops.md) |
| DNS issues | [runbooks/dns-resolution-issues.md](runbooks/dns-resolution-issues.md) |
| Node updates | [NODE-UPDATES.md](NODE-UPDATES.md) |
| Flux GitOps | [gitops/flux-overview.md](gitops/flux-overview.md) |
| SOPS secrets | [SOPS-SETUP.md](SOPS-SETUP.md) |
| VPN architecture | [architecture/vpn-wireguard.md](architecture/vpn-wireguard.md) |
| AWS infrastructure | [architecture/aws-infrastructure.md](architecture/aws-infrastructure.md) |

---

## 8. Regular Maintenance Tasks

### Weekly
- [ ] Review Grafana dashboards for anomalies
- [ ] Check `flux get all -A` for failed reconciliations
- [ ] Review pending alerts in Alertmanager

### Monthly
- [ ] Check for Helm chart updates
- [ ] Review unattended-upgrades logs on standalone VMs
- [ ] Verify backups are completing successfully
- [ ] Update documentation for any changes made

### Quarterly
- [ ] Evaluate Kubernetes version upgrade
- [ ] Review and update alerting thresholds
- [ ] Audit secrets and rotate if needed
- [ ] Test disaster recovery procedures

---

## 9. Emergency Contacts & Escalation

### Self-Healing Capabilities

The infrastructure is designed to self-heal:

1. **DNS failure**: Technitium cluster (4 nodes) provides redundancy
2. **VPN failure**: Local services continue; AWS isolated but functional
3. **K8s node failure**: Workloads reschedule to other nodes
4. **Pod crash**: Kubernetes restarts automatically
5. **Security update**: Auto-applied with coordinated reboots

### When Manual Intervention Required

- Kubernetes API server down
- All DNS nodes failing simultaneously
- VPN private keys compromised
- Storage cluster (Ceph) degraded
- Multiple node failures

### External Dependencies

| Service | Purpose | Failure Impact |
|---------|---------|----------------|
| GitHub | GitOps source | No new deployments until restored |
| AWS | VPN endpoint, DNS failover | Remote access lost |
| Cloudflare | DNS for public domains | External access affected |
| Let's Encrypt | TLS certificates | Cert renewal fails (90-day buffer) |
