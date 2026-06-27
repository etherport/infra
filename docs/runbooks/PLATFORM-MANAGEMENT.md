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
│  │  Control Plane (HA):  k8s-cp1 (.50)  k8s-cp2 (.51)  k8s-cp3 (.52)   │   │
│  │  Workers:             k8s-w1 (.53)   k8s-w2 (.54)                   │   │
│  │                       k8s-w3 (.55)   k8s-w4 (.56)                   │   │
│  │  GPU:                 k8s-gpu1 (.60) — NVIDIA Tesla P40             │   │
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
│  │  ┌─────────────┐                                                    │   │
│  │  │ gh-runner   │  GitHub Actions self-hosted runner (VM 1003,      │   │
│  │  │10.10.201.x  │  10.10.201.x — see infra/ansible/playbooks/       │   │
│  │  │ Actions     │  gh-runner.yml)                                   │   │
│  │  └─────────────┘                                                    │   │
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
kubectl get gitrepository,kustomization,helmrelease -A

# Standalone VMs
for host in 10.10.201.6 10.10.201.15 10.10.100.5 10.10.100.10; do
  echo -n "$host: "
  curl -s --connect-timeout 2 "http://$host:9100/metrics" | grep -c "^node_" || echo "DOWN"
done

# DNS
dig @10.10.201.5 google.com +short

# VPN — vpn-local + dns-fallback rebuilt 2026-05 onto the Ubuntu 24.04
# template (VM 9001); both now use `ubuntu` + /tmp/auto-key like the
# K8s nodes (C2 done).
ssh -i /tmp/auto-key ubuntu@10.10.201.15 "sudo wg show"
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

Full ownership matrix + restore procedures: [`disaster-recovery.md`](disaster-recovery.md) §10.

| Component | Method | Frequency |
|-----------|--------|-----------|
| K8s workloads + PVs | Velero (10 schedules) → Kopia → S3 | Daily |
| Postgres (CNPG) | Barman continuous WAL + nightly base → S3 | Continuous |
| etcd | systemd timer per CP + Velero ships /var/lib/etcd-snapshots | Daily 02:00 PT |
| UDM + Protect config | unifi-backup CronJob → S3 | Daily 04:00 PT |
| NAS shares (7) | s3-sync CronJob per share → per-share S3 buckets | Daily 01:00 PT |
| Google Drive | rclone gdrive-sync → NFS mirror | Daily 00:00 PT |
| Proxmox VMs | Proxmox Backup | Weekly |
| Git repo | GitHub | Every push |
| DNS zones | Technitium cluster sync | Real-time |

### Self-Healing Capabilities

The infrastructure is designed to self-heal:
- **DNS failure**: Technitium cluster (in-cluster STS pair + dns-fallback + dns-aws) provides redundancy
- **VPN failure**: K8s WireGuard pod ⇄ `vpn-local` VRRP failover (VIP 10.10.201.20); on K8s pod loss, vpn-local takes over in ~10-15s
- **K8s node failure**: Workloads reschedule; Prometheus + Alertmanager run replicas=2 with podAntiAffinity
- **Pod crash**: Kubernetes restarts automatically; auto-remediation controller layers static rules + AI advisor (Phase 3 live for opted-in alerts — `ai_remediation: auto`)
- **Closed-loop verification**: every advisor auto-execute is re-checked N min later; failure surfaces as a `verification_failed` audit event + email
- **Security updates**: Auto-applied with coordinated reboots via kured + unattended-upgrades
- **Appliance probing**: blackbox-exporter (ICMP + HTTPS) on UDM / Protect / UNAS → status email + Grafana dashboard
- **AWS-side observability**: cloudwatch-to-loki forwarder makes Lambda + EC2 cw-agent logs queryable in the same Loki as on-prem K8s/syslog

---

## Regular Maintenance Tasks

### Weekly
- [ ] Review Grafana dashboards for anomalies
- [ ] Check `kubectl get gitrepository,kustomization,helmrelease -A` for failed reconciliations
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
