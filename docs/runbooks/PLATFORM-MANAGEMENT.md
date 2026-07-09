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
│  │  Control Plane (x3):  k8s-cp1 (.50)  k8s-cp2 (.51)  k8s-cp3 (.52)   │   │
│  │  Workers:             k8s-w1 (.53)   k8s-w2 (.54)                   │   │
│  │                       k8s-w3 (.55)   k8s-w4 (.56)                   │   │
│  │  GPU:                 k8s-gpu1 (.60) — NVIDIA Tesla P40             │   │
│  │                                                                     │   │
│  │  Version: v1.35.0 (kubespray)                                      │   │
│  │  Updates: kured reboots + unattended-upgrades security-only (M116) │   │
│  │  Apps: Flux GitOps + Helm                                          │   │
│  │  Monitoring: Prometheus + Grafana                                  │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    Standalone VMs (Non-K8s)                          │   │
│  │  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐   │   │
│  │  │dns-fallback │ │ vpn-fallback   │ │  edge box   │ │ dns-aws:    │   │   │
│  │  │ 10.10.201.6 │ │10.10.201.15 │ │10.10.100.10 │ │ removed     │   │   │
│  │  │ Technitium  │ │ WireGuard   │ │ WG+DNS+TS   │ │ (M110)      │   │   │
│  │  └─────────────┘ └─────────────┘ └─────────────┘ └─────────────┘   │   │
│  │  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐   │   │
│  │  │ gh-runner   │ │asterisk-sbc │ │   devbox    │ │  step-ca    │   │   │
│  │  │10.10.201.30 │ │10.10.201.40 │ │10.10.201.45 │ │10.10.201.46 │   │   │
│  │  │ Actions     │ │ Asterisk    │ │ Dev/Claude  │ │ SSH CA      │   │   │
│  │  │ (VM 1003)   │ │ SBC (1004)  │ │ (M81, 1005) │ │ (M76, 1006) │   │   │
│  │  └─────────────┘ └─────────────┘ └─────────────┘ └─────────────┘   │   │
│  │                                                                     │   │
│  │  Updates: unattended-upgrades (automatic with staggered reboots)   │   │
│  │  Config: Ansible playbooks                                         │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

> NB: there is **no HA API VIP** — `controlPlaneEndpoint` pins **cp1** (`10.10.201.50`);
> workers use their local `nginx-proxy`. See CLAUDE.md §3 before patching CP nodes.
>
> **M110 done (2026-07-02):** the two AWS VMs were consolidated into one — `vpn-aws`
> was resized to t4g.small (AWS tag now `private-infra_edge`) and now runs WireGuard,
> Tailscale, **and** Technitium DNS (on 10.10.100.10 / EIP 44.240.60.80). The former
> `dns-aws` (10.10.100.5) was **destroyed** and its EIP `52.40.219.113` **released**.
> There is now exactly one standing AWS EC2 instance, on **cert-only SSH** like the
> rest of the fleet (M76 parity, 2026-07-03; the static key survives only as the
> cloud-init rebuild seed).

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
for host in 10.10.201.6 10.10.201.15 10.10.100.10; do
  echo -n "$host: "
  curl -s --connect-timeout 2 "http://$host:9100/metrics" | grep -c "^node_" || echo "DOWN"
done

# DNS
# .5 is the in-cluster Technitium MetalLB VIP — BGP-only/no-L2, so it is NOT
# reachable from a host ON VLAN 201 (e.g. the devbox where these checks run):
# same-subnet ARP for the VIP fails and the dig times out even when DNS is healthy.
# From an on-201 host, query dns-fallback (.6) instead, or add a /32 route via the UDM.
dig @10.10.201.5 google.com +short   # off-VLAN-201 only
dig @10.10.201.6 google.com +short   # dns-fallback — use this from an on-201 host

# VPN — cert-only SSH (M76)
ssh ubuntu@10.10.201.15 "sudo wg show"
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
| K8s workloads + PVs | Velero → local **Garage** (S3-on-NAS) primary; S3 = read-only DR + weekly Deep-Archive `dr/` (M137) | Daily |
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
- **DNS failure**: Technitium cluster (in-cluster STS pair + dns-fallback + the AWS edge box) provides redundancy
- **VPN failure**: K8s WireGuard pod ⇄ `vpn-fallback` VRRP failover (VIP 10.10.201.20); on K8s pod loss, vpn-fallback takes over in ~10-15s. ⚠️ Fail-*back* to the pod is not always automatic — see the sticky-failover caveat in [vpn-wireguard.md](../architecture/vpn-wireguard.md)
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
