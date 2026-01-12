# System Update Procedures

Comprehensive guide for updating all infrastructure components.

## Update Automation Overview

| Component | Method | Automation Level | Action Required |
|-----------|--------|------------------|-----------------|
| Container Images (13) | Flux ImageUpdateAutomation | Fully Auto | None - commits to git automatically |
| K8s Node OS | unattended-upgrades + Kured | Fully Auto | None - patches + reboots automatically |
| Standalone VM OS | unattended-upgrades | Fully Auto | None - patches + reboots automatically |
| Helm Charts | Renovate | PR Created | Review and merge PR |
| Terraform Providers | Renovate | PR Created | Review and merge PR |
| GitHub Actions | Renovate | PR Created | Review and merge PR |
| Proxmox Host | Ansible Playbook | Manual | Run playbook |
| Kubernetes Version | Kubespray | Manual | Run playbook |
| GPU Drivers | Manual | Manual | SSH and update |

---

## Fully Automated Updates (No Action Required)

### Container Images via Flux

**What's automated:** 13 container images are automatically updated when new versions are released.

**How it works:**
1. Flux ImageRepository scans registries hourly
2. ImagePolicy selects latest version matching constraints
3. ImageUpdateAutomation commits tag update to git
4. Flux deploys the new version

**Tracked images:**
- ollama, open-webui, technitium, wikijs, plex
- kopia, rclone, icloudpd, home-assistant
- python:alpine, python:slim, busybox, velero-plugin-aws

**Monitor status:**
```bash
# Check all image policies
flux get images policy -A

# Check automation status
kubectl get imageupdateautomation -n flux-system

# View recent automated commits
git log --oneline --author="Flux" -10
```

**Rollback if needed:**
```bash
# Revert to previous image version
git revert <commit-sha>
git push
flux reconcile kustomization flux-system --with-source
```

---

### K8s Node OS Updates

**What's automated:** Security patches applied daily, reboots coordinated via Kured.

**How it works:**
1. `unattended-upgrades` installs security patches (runs daily)
2. Patches requiring reboot create `/var/run/reboot-required`
3. Kured detects flag and schedules reboot during maintenance window (2-6am Pacific)
4. Kured cordons node, drains pods, reboots, waits for ready

**Monitor status:**
```bash
# Check Kured status
kubectl get ds kured -n kube-system

# Check if nodes need reboot
ansible k8s_cluster -i infra/ansible/inventory/wind/inventory.ini \
  -a "cat /var/run/reboot-required 2>/dev/null || echo 'No reboot needed'"

# Check recent reboots
kubectl get events -A --field-selector reason=Rebooted
```

---

### Standalone VM OS Updates

**What's automated:** Security patches + auto-reboot with staggered timing.

**Reboot schedule:**
- dns-fallback: 02:00
- dns-aws: 02:30
- vpn-local: 03:00
- vpn-aws: 03:30

**Monitor status:**
```bash
# Check pending reboots
ansible dns_servers,vpn_servers \
  -i infra/ansible/inventory/wind/inventory.ini \
  -i infra/ansible/inventory/aws/inventory.ini \
  -a "cat /var/run/reboot-required 2>/dev/null || echo 'No reboot needed'"

# Check last reboot time
ansible all -i infra/ansible/inventory/wind/inventory.ini -a "uptime"
```

---

## Semi-Automated Updates (Review + Merge)

### Renovate PRs

**What Renovate tracks:**
- Terraform providers (proxmox, aws, etc.)
- Container images NOT managed by Flux
- GitHub Actions versions
- Any dependencies in supported formats

**Workflow:**
1. Renovate scans repo (continuous)
2. Creates PR when update available
3. **You review the PR:**
   - Check release notes for breaking changes
   - Verify CI passes (if configured)
   - Consider impact on running systems
4. Merge PR
5. Flux deploys changes (if applicable)

**View open Renovate PRs:**
```bash
# Via GitHub CLI
gh pr list --repo sparked-diamond/infra --label renovate

# Or visit: https://github.com/sparked-diamond/infra/pulls
```

**Renovate commands (comment on PR):**
```
@renovate rebase          # Rebase PR on latest main
@renovate recreate        # Recreate PR from scratch
@renovate retry           # Retry failed update
```

---

## Manual Updates

### Proxmox Host Updates

**When to update:** Monthly or when security advisories released.

**Procedure:**
```bash
cd ~/Projects/homelab-infra/infra/ansible

# 1. Check for available updates (dry-run)
ansible-playbook -i inventory/wind/ playbooks/proxmox.yml --check

# 2. Review what will be updated
ansible-playbook -i inventory/wind/ playbooks/proxmox.yml --check --diff

# 3. Apply updates (no reboot)
ansible-playbook -i inventory/wind/ playbooks/proxmox.yml

# 4. If reboot required, schedule maintenance window then:
ansible-playbook -i inventory/wind/ playbooks/proxmox.yml -e "allow_reboot=true"
```

**Pre-update checklist:**
- [ ] Verify VM backups are current
- [ ] Check Proxmox cluster health (if clustered)
- [ ] Schedule during low-usage period
- [ ] Notify users if extended downtime expected

**Post-update verification:**
```bash
# Check Proxmox version
ssh graham@pve.wind.etherport.net "pveversion"

# Verify all VMs running
ssh graham@pve.wind.etherport.net "qm list"

# Check cluster health
ssh graham@pve.wind.etherport.net "pvecm status"
```

---

### Kubernetes Version Upgrade

**When to update:** Quarterly or for security patches. Always test in non-prod first.

**Procedure:**
```bash
cd ~/Projects/homelab-infra/infra/kubespray

# 1. Update Kubespray submodule to desired version
git submodule update --remote kubespray
cd kubespray
git checkout v2.XX.X  # Specific release tag
cd ..

# 2. Review upgrade path
# Check: https://github.com/kubernetes-sigs/kubespray/blob/master/docs/upgrades.md

# 3. Run upgrade playbook
ansible-playbook -i ../ansible/inventory/wind/inventory.ini \
  kubespray/upgrade-cluster.yml \
  -b --become-user=root

# 4. Verify cluster health
kubectl get nodes
kubectl get pods -A | grep -v Running
```

**Pre-upgrade checklist:**
- [ ] Backup etcd: `kubectl exec -n kube-system etcd-k8s-cp1 -- etcdctl snapshot save /tmp/backup.db`
- [ ] Review Kubernetes changelog for breaking changes
- [ ] Test upgrade in staging if available
- [ ] Ensure Velero backups are current

---

### Helm Chart Updates

**When to update:** When Renovate creates PR, or manually for urgent updates.

**Manual update procedure:**
```bash
# 1. Check current versions
helm list -A

# 2. Check for updates
helm repo update
helm search repo <chart-name> --versions

# 3. Review release notes
# Visit chart's GitHub/documentation

# 4. Update values file if needed
vim platform/kubernetes/<app>/values.yaml

# 5. Upgrade release
helm upgrade <release-name> <repo/chart> \
  -n <namespace> \
  -f platform/kubernetes/<app>/values.yaml

# 6. Verify deployment
kubectl rollout status deployment/<name> -n <namespace>

# 7. Commit changes to git
git add platform/kubernetes/<app>/values.yaml
git commit -m "chore(deps): update <chart> to vX.Y.Z"
git push
```

**Current Helm releases:**
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

### GPU Driver Updates (k8s-gpu1)

**When to update:** When NVIDIA releases security patches or new features needed.

**Note:** GPU Operator manages driver installation. Update the operator to get new drivers.

```bash
# Check current driver version
kubectl exec -it -n gpu-operator-system $(kubectl get pods -n gpu-operator-system -l app=nvidia-driver-daemonset -o jsonpath='{.items[0].metadata.name}') -- nvidia-smi

# Update GPU Operator (via Helm)
helm repo update
helm upgrade gpu-operator nvidia/gpu-operator \
  -n gpu-operator-system \
  -f platform/kubernetes/gpu-operator/values.yaml
```

---

## Update Schedules

### Recommended Cadence

| Component | Frequency | Best Time |
|-----------|-----------|-----------|
| Container images | Automatic (continuous) | N/A |
| K8s node OS | Automatic (daily patches) | 2-6am Pacific |
| Standalone VM OS | Automatic (daily patches) | 2-4am Pacific |
| Renovate PRs | Weekly review | Monday morning |
| Proxmox host | Monthly | Weekend maintenance |
| Kubernetes version | Quarterly | Weekend maintenance |
| Helm charts | As PRs arrive | Weekday, monitor after |

### Maintenance Windows

- **Daily (automatic):** 2-6am Pacific - OS patches, Kured reboots
- **Weekly (manual review):** Monday AM - Review and merge Renovate PRs
- **Monthly (manual):** First weekend - Proxmox updates
- **Quarterly (manual):** Kubernetes version upgrades

---

## Monitoring Updates

### Grafana Dashboards

- Node Exporter: OS metrics, uptime
- Kubernetes: Pod restarts, node status
- Flux: Reconciliation status

### Alerts to Watch

- Pod CrashLoopBackOff after updates
- Node NotReady after reboots
- Flux reconciliation failures
- Kured holding lock too long

### Useful Commands

```bash
# Recent image updates by Flux
git log --oneline --author="Flux" --since="7 days ago"

# Pending Renovate PRs
gh pr list --label renovate

# Nodes pending reboot
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.kured\.dev/reboot-required}{"\n"}{end}'

# Recent pod restarts (may indicate update issues)
kubectl get pods -A --sort-by='.status.containerStatuses[0].restartCount' | tail -20
```

---

## Troubleshooting Updates

### Flux Image Update Stuck

```bash
# Check automation status
kubectl describe imageupdateautomation flux-system -n flux-system

# Check if git push is working
kubectl logs -n flux-system deployment/image-automation-controller

# Force reconciliation
flux reconcile image update flux-system -n flux-system
```

### Kured Not Rebooting

```bash
# Check Kured logs
kubectl logs -n kube-system -l app.kubernetes.io/name=kured

# Check if within schedule
# Kured only reboots during configured window (2-6am Pacific)

# Manual unlock if stuck
kubectl annotate node <node-name> kured.dev/reboot-in-progress-
```

### Renovate Not Creating PRs

1. Check Renovate dashboard: https://developer.mend.io/github/sparked-diamond/infra
2. Check for open "Action Required" issues
3. Verify `renovate.json` is valid JSON
4. Check schedule settings (currently "at any time")

### Helm Upgrade Failed

```bash
# Check release status
helm status <release> -n <namespace>

# View release history
helm history <release> -n <namespace>

# Rollback to previous
helm rollback <release> <revision> -n <namespace>
```

---

## References

- [Flux Image Automation](https://fluxcd.io/flux/guides/image-update/)
- [Renovate Documentation](https://docs.renovatebot.com/)
- [Kured Documentation](https://kured.dev/docs/)
- [Kubespray Upgrades](https://kubespray.io/#/docs/upgrades)
- [Helm Upgrade](https://helm.sh/docs/helm/helm_upgrade/)
