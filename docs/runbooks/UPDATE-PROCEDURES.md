# System Update Procedures

Single source of truth for all infrastructure update procedures.

---

## Quick Reference: What Updates Automatically?

```
┌──────────────────────────────────────────────────────────────────┐
│                    FULLY AUTOMATIC                               │
│                    (no action needed)                            │
├──────────────────────────────────────────────────────────────────┤
│  Container Images (13)    Flux scans hourly, commits to git      │
│  K8s Node OS Patches      unattended-upgrades runs daily         │
│  K8s Node Reboots         Kured coordinates 2-6am Pacific        │
│  Standalone VM OS         unattended-upgrades + auto-reboot      │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│                    SEMI-AUTOMATIC                                │
│                    (review & merge PRs)                          │
├──────────────────────────────────────────────────────────────────┤
│  Helm Charts              Renovate creates PRs on new releases   │
│  Terraform Providers      Renovate creates PRs on new releases   │
│  GitHub Actions           Renovate creates PRs on new releases   │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│                    MANUAL                                        │
│                    (run playbook/commands)                       │
├──────────────────────────────────────────────────────────────────┤
│  Proxmox Host OS          Ansible playbook (monthly)             │
│  Kubernetes Version       Kubespray (quarterly)                  │
│  GPU Drivers              GPU Operator Helm upgrade              │
└──────────────────────────────────────────────────────────────────┘
```

---

## Update Timeline

```
DAILY (Automatic - no action needed)
──────────────────────────────────────────────────────────────────
  Continuous    Container images scanned & updated (Flux)
  ~04:00        Security patches installed (unattended-upgrades)
  02:00-06:00   K8s node reboots if needed (Kured, one at a time)
  02:00         dns-fallback reboot window
  02:30         dns-aws reboot window
  03:00         vpn-local reboot window
  03:30         vpn-aws reboot window

WEEKLY (Review required)
──────────────────────────────────────────────────────────────────
  Monday AM     Review and merge Renovate PRs
                └── Helm charts, Terraform providers, GitHub Actions

MONTHLY (Manual)
──────────────────────────────────────────────────────────────────
  1st Weekend   Proxmox host updates
                └── Run: ansible-playbook playbooks/proxmox.yml

QUARTERLY (Manual - requires maintenance window)
──────────────────────────────────────────────────────────────────
  Scheduled     Kubernetes version upgrade (Kubespray)
  Weekend       └── See kubernetes-upgrade.md for full procedure
```

---

## Detailed Status Table

| Component | Count | Method | Frequency | Action |
|-----------|-------|--------|-----------|--------|
| Container Images | 13 | Flux ImageUpdateAutomation | Hourly scan | None |
| K8s Node OS | 5 nodes | unattended-upgrades | Daily | None |
| K8s Node Reboots | 5 nodes | Kured | 2-6am when needed | None |
| Standalone VM OS | 4 VMs | unattended-upgrades | Daily | None |
| Standalone VM Reboots | 4 VMs | Staggered cron | 02:00-04:00 | None |
| Helm Charts | 7 releases | Renovate PRs | On release | Merge PR |
| Terraform Providers | 3 | Renovate PRs | On release | Merge PR |
| GitHub Actions | varies | Renovate PRs | On release | Merge PR |
| Proxmox Host | 1 | Ansible | Monthly | Run playbook |
| Kubernetes Version | cluster | Kubespray | Quarterly | Run playbook |
| GPU Drivers | 1 node | GPU Operator | As needed | Helm upgrade |

---

## 1. Fully Automatic Updates

### 1.1 Container Images (Flux)

**Images tracked (14):**
- ollama, open-webui, technitium, wikijs, plex
- rclone, home-assistant, cue, cloudflared
- python:alpine, python:slim, busybox, blackbox-exporter, velero-plugin-aws

**How it works:**
1. Flux ImageRepository scans registries hourly
2. ImagePolicy selects latest version matching constraints
3. ImageUpdateAutomation commits tag update to git
4. Flux deploys the new version

**Monitor:**
```bash
flux get images policy -A                              # Current versions
kubectl get imageupdateautomation -n flux-system       # Automation status
git log --oneline --author="Flux" -10                  # Recent auto-commits
```

**Rollback:**
```bash
git revert <commit-sha> && git push
flux reconcile kustomization flux-system --with-source
```

---

### 1.2 Kubernetes Node OS

**Nodes:** k8s-cp1, k8s-w1, k8s-w2, k8s-w3, k8s-gpu1

**How it works:**
1. `unattended-upgrades` installs security patches daily
2. Creates `/var/run/reboot-required` when reboot needed
3. Kured detects flag, schedules reboot during 2-6am Pacific
4. Kured cordons node, drains pods, reboots, waits for ready
5. Only one node reboots at a time

**Monitor:**
```bash
kubectl get ds kured -n kube-system
kubectl logs -n kube-system -l app.kubernetes.io/name=kured --tail=20

# Check if nodes need reboot
ansible k8s_cluster -i infra/ansible/inventory/wind/inventory.ini \
  -a "cat /var/run/reboot-required 2>/dev/null || echo 'No reboot needed'"
```

---

### 1.3 Standalone VM OS

**VMs and reboot schedule:**
| VM | IP | Purpose | Reboot Time |
|----|-----|---------|-------------|
| dns-fallback | 10.10.201.6 | Backup DNS | 02:00 |
| dns-aws | 10.10.100.5 | AWS DNS | 02:30 |
| vpn-local | 10.10.201.15 | Local VPN | 03:00 |
| vpn-aws | 10.10.100.10 | AWS VPN | 03:30 |

**Monitor:**
```bash
ansible dns_servers,vpn_servers \
  -i infra/ansible/inventory/wind/inventory.ini \
  -i infra/ansible/inventory/aws/inventory.ini \
  -a "cat /var/run/reboot-required 2>/dev/null || echo 'No reboot needed'"
```

---

## 2. Semi-Automatic Updates (Renovate PRs)

**What Renovate tracks:**
- Helm chart versions
- Terraform provider versions
- GitHub Actions versions

**Workflow:**
1. Renovate scans repo continuously
2. Creates PR when update available
3. You review the PR (check release notes)
4. Merge PR
5. Flux/Terraform applies changes

**View open PRs:**
```bash
gh pr list --label renovate
# Or: https://github.com/sparked-diamond/infra/pulls
```

**Current Helm releases tracked:**
| Release | Chart | Namespace |
|---------|-------|-----------|
| cert-manager | jetstack/cert-manager | cert-manager |
| cnpg | cnpg/cloudnative-pg | cnpg-system |
| gpu-operator | nvidia/gpu-operator | gpu-operator-system |
| kured | kubereboot/kured | kube-system |
| monitoring | prometheus-community/kube-prometheus-stack | monitoring |
| traefik | traefik/traefik | traefik |
| velero | vmware-tanzu/velero | velero |

---

## 3. Manual Updates

### 3.1 Proxmox Host (Monthly)

```bash
cd ~/Projects/homelab-infra/infra/ansible

# Dry-run
ansible-playbook -i inventory/wind/ playbooks/proxmox.yml --check --diff

# Apply updates
ansible-playbook -i inventory/wind/ playbooks/proxmox.yml

# If reboot required
ansible-playbook -i inventory/wind/ playbooks/proxmox.yml -e "allow_reboot=true"
```

**Pre-update:** Verify VM backups are current, schedule low-usage period.

---

### 3.2 Kubernetes Version (Quarterly)

**Full procedure:** See [kubernetes-upgrade.md](kubernetes-upgrade.md)

```bash
cd ~/Projects/homelab-infra/infra/kubespray

# Update Kubespray
git submodule update --remote kubespray
cd kubespray && git checkout v2.XX.X && cd ..

# Run upgrade
ansible-playbook -i ../ansible/inventory/wind/inventory.ini \
  kubespray/upgrade-cluster.yml -b --become-user=root

# Verify
kubectl get nodes
kubectl get pods -A | grep -v Running
```

**Pre-upgrade:** Backup etcd, review K8s changelog, ensure Velero backups current.

---

### 3.3 GPU Drivers

GPU Operator manages drivers. Update the operator to get new drivers:

```bash
# Check current version
kubectl exec -it -n gpu-operator-system \
  $(kubectl get pods -n gpu-operator-system -l app=nvidia-driver-daemonset -o jsonpath='{.items[0].metadata.name}') \
  -- nvidia-smi

# Update operator
helm repo update
helm upgrade gpu-operator nvidia/gpu-operator \
  -n gpu-operator-system \
  -f platform/kubernetes/gpu-operator/values.yaml
```

---

## 4. Troubleshooting

### Flux Image Update Stuck
```bash
kubectl describe imageupdateautomation flux-system -n flux-system
kubectl logs -n flux-system deployment/image-automation-controller
flux reconcile image update flux-system -n flux-system
```

### Kured Not Rebooting
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=kured
# Note: Only reboots during 2-6am Pacific window
# Manual unlock if stuck:
kubectl annotate node <node-name> kured.dev/reboot-in-progress-
```

### Renovate Not Creating PRs
1. Check: https://developer.mend.io/github/sparked-diamond/infra
2. Look for "Action Required" issues
3. Verify `renovate.json` is valid

### Helm Upgrade Failed
```bash
helm status <release> -n <namespace>
helm history <release> -n <namespace>
helm rollback <release> <revision> -n <namespace>
```

---

## Related Documentation

- [kubernetes-upgrade.md](kubernetes-upgrade.md) - Detailed K8s upgrade procedures
- [disaster-recovery.md](disaster-recovery.md) - Recovery procedures
- [operations-guide.md](operations-guide.md) - Command quick reference
