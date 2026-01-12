# Platform Management Guide

High-level overview of the homelab infrastructure with links to detailed runbooks.

---

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
│  │  Updates: Kured + unattended-upgrades (automatic)                  │   │
│  │  Apps: Flux GitOps + Helm                                          │   │
│  │  Monitoring: Prometheus + Grafana                                  │   │
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
│  │  Updates: unattended-upgrades (automatic with staggered reboots)   │   │
│  │  Config: Ansible playbooks                                         │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Quick Access

| Service | URL | Purpose |
|---------|-----|---------|
| Grafana | https://grafana.wind.etherport.net | Dashboards |
| Prometheus | Internal (port-forward 9090) | Metrics |
| Technitium DNS | https://dns.wind.etherport.net:5380 | DNS management |
| Wiki.js | https://wiki.wind.etherport.net | Documentation |
| Open WebUI | https://llm.wind.etherport.net | LLM interface |

---

## Quick Health Check

```bash
# Kubernetes
kubectl get nodes -o wide
kubectl get pods -A | grep -v Running | grep -v Completed
flux get all -A

# Standalone VMs
for host in 10.10.201.6 10.10.201.15 10.10.100.5 10.10.100.10; do
  echo -n "$host: "
  curl -s --connect-timeout 2 "http://$host:9100/metrics" | grep -c "^node_" || echo "DOWN"
done

# DNS
dig @10.10.201.5 google.com +short

# VPN
ssh graham@10.10.201.15 "sudo wg show"
```

---

## Runbook Quick Links

### Operations
| Topic | Document |
|-------|----------|
| **Updates & Maintenance** | [UPDATE-PROCEDURES.md](UPDATE-PROCEDURES.md) |
| Command Reference | [operations-guide.md](operations-guide.md) |
| Kubernetes Upgrade | [kubernetes-upgrade.md](kubernetes-upgrade.md) |
| Disaster Recovery | [disaster-recovery.md](disaster-recovery.md) |
| DNS Issues | [dns-resolution-issues.md](dns-resolution-issues.md) |

### Architecture
| Topic | Document |
|-------|----------|
| Overview | [../architecture/overview.md](../architecture/overview.md) |
| Network | [../architecture/network.md](../architecture/network.md) |
| VPN | [../architecture/vpn-wireguard.md](../architecture/vpn-wireguard.md) |
| AWS | [../architecture/aws-infrastructure.md](../architecture/aws-infrastructure.md) |

### GitOps & Deployment
| Topic | Document |
|-------|----------|
| Flux Overview | [../setup/gitops/flux-overview.md](../setup/gitops/flux-overview.md) |
| Making Changes | [../setup/gitops/making-changes.md](../setup/gitops/making-changes.md) |
| Secrets (SOPS) | [../setup/secrets/SOPS-SETUP.md](../setup/secrets/SOPS-SETUP.md) |

---

## Key Infrastructure Details

### Deployment Methods

| Method | Use Case | Rollback |
|--------|----------|----------|
| **Flux GitOps** | Apps in `platform/kubernetes/` | `git revert` |
| **Helm** | Complex charts (Prometheus, Velero) | `helm rollback` |
| **Ansible** | Standalone VM configuration | Re-run playbook |

### Backup Coverage

| Component | Method | Frequency |
|-----------|--------|-----------|
| K8s workloads | Velero | Daily |
| K8s PVCs | Velero + Restic | Daily |
| Proxmox VMs | Proxmox Backup | Weekly |
| Git repo | GitHub | Every push |
| DNS zones | Technitium cluster sync | Real-time |

### Self-Healing Capabilities

The infrastructure is designed to self-heal:
- **DNS failure**: Technitium cluster (4 nodes) provides redundancy
- **VPN failure**: Local services continue; AWS isolated but functional
- **K8s node failure**: Workloads reschedule to other nodes
- **Pod crash**: Kubernetes restarts automatically
- **Security updates**: Auto-applied with coordinated reboots

---

## Regular Maintenance Tasks

### Weekly
- [ ] Review Grafana dashboards for anomalies
- [ ] Check `flux get all -A` for failed reconciliations
- [ ] Review and merge Renovate PRs

### Monthly
- [ ] Run Proxmox host updates
- [ ] Verify backups are completing
- [ ] Update documentation for changes made

### Quarterly
- [ ] Evaluate Kubernetes version upgrade
- [ ] Audit secrets and rotate if needed
- [ ] Test disaster recovery procedures

**Detailed update procedures:** [UPDATE-PROCEDURES.md](UPDATE-PROCEDURES.md)
