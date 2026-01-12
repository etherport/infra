# Homelab Infrastructure Documentation

Central documentation index for the homelab infrastructure project.

## Quick Start

| I want to... | Go to... |
|--------------|----------|
| Understand the platform | [PLATFORM-MANAGEMENT.md](PLATFORM-MANAGEMENT.md) |
| Check update status | [runbooks/UPDATE-PROCEDURES.md](runbooks/UPDATE-PROCEDURES.md) |
| Run operational commands | [runbooks/operations-guide.md](runbooks/operations-guide.md) |
| Deploy changes via GitOps | [gitops/making-changes.md](gitops/making-changes.md) |
| Recover from failures | [runbooks/disaster-recovery.md](runbooks/disaster-recovery.md) |

---

## Documentation Index

### Operations & Runbooks

| Document | Description |
|----------|-------------|
| [PLATFORM-MANAGEMENT.md](PLATFORM-MANAGEMENT.md) | High-level platform overview and quick links |
| [runbooks/UPDATE-PROCEDURES.md](runbooks/UPDATE-PROCEDURES.md) | **All update procedures** - automatic, semi-auto, manual |
| [runbooks/operations-guide.md](runbooks/operations-guide.md) | Command reference for all operations |
| [runbooks/kubernetes-upgrade.md](runbooks/kubernetes-upgrade.md) | Kubernetes version upgrade procedures |
| [runbooks/disaster-recovery.md](runbooks/disaster-recovery.md) | Recovery procedures for failure scenarios |
| [runbooks/dns-resolution-issues.md](runbooks/dns-resolution-issues.md) | DNS troubleshooting |
| [runbooks/vlan-interfaces-netplan.md](runbooks/vlan-interfaces-netplan.md) | VLAN interface configuration |
| [runbooks/auto-remediation/](runbooks/auto-remediation/) | Automated issue resolution system |

### Architecture

| Document | Description |
|----------|-------------|
| [architecture/overview.md](architecture/overview.md) | High-level infrastructure design |
| [architecture/network.md](architecture/network.md) | Network topology and VLANs |
| [architecture/firewall-zones.md](architecture/firewall-zones.md) | Zone-based firewall configuration |
| [architecture/vpn-wireguard.md](architecture/vpn-wireguard.md) | Site-to-site VPN configuration |
| [architecture/aws-infrastructure.md](architecture/aws-infrastructure.md) | AWS hybrid cloud components |

### GitOps and Deployment

| Document | Description |
|----------|-------------|
| [gitops/flux-overview.md](gitops/flux-overview.md) | Flux GitOps workflow and patterns |
| [gitops/making-changes.md](gitops/making-changes.md) | How to make changes via GitOps |
| [git/repo-workflow.md](git/repo-workflow.md) | Git repository workflow |
| [VERSIONING-STRATEGY.md](VERSIONING-STRATEGY.md) | Container image versioning approach |

### Secrets Management

| Document | Description |
|----------|-------------|
| [SOPS-SETUP.md](SOPS-SETUP.md) | Secret encryption with SOPS + age |
| [1PASSWORD-CLI.md](1PASSWORD-CLI.md) | 1Password CLI integration |
| [decisions/sops-vs-ansible-vault.md](decisions/sops-vs-ansible-vault.md) | SOPS vs Ansible-Vault comparison |

### Kubernetes

| Document | Description |
|----------|-------------|
| [kubernetes/cluster-build-kubespray.md](kubernetes/cluster-build-kubespray.md) | Cluster provisioning with Kubespray |
| [kubernetes/kubectl-cheatsheet.md](kubernetes/kubectl-cheatsheet.md) | kubectl command reference |
| [kubernetes/kustomize-patterns.md](kubernetes/kustomize-patterns.md) | Kustomize patterns and examples |
| [kubernetes/addons-metallb.md](kubernetes/addons-metallb.md) | MetalLB load balancer setup |
| [kubernetes/ingress-traefik.md](kubernetes/ingress-traefik.md) | Traefik ingress configuration |
| [kubernetes/storage-ceph-csi.md](kubernetes/storage-ceph-csi.md) | Ceph CSI storage setup |
| [kubernetes/monitoring-kube-prometheus-stack.md](kubernetes/monitoring-kube-prometheus-stack.md) | Prometheus monitoring stack |
| [kubernetes/node-vlan-setup.md](kubernetes/node-vlan-setup.md) | Node VLAN configuration |

### Terraform

| Document | Description |
|----------|-------------|
| [terraform/proxmox-k8s-vms.md](terraform/proxmox-k8s-vms.md) | Proxmox VM provisioning |
| [terraform/remote-state-backend.md](terraform/remote-state-backend.md) | Terraform state in S3 |

### Guides

| Document | Description |
|----------|-------------|
| [guides/localtuya/](guides/localtuya/) | LocalTuya setup for IoT devices |

### Planning and Reference

| Document | Description |
|----------|-------------|
| [PRODUCTION-READINESS-CHECKLIST.md](PRODUCTION-READINESS-CHECKLIST.md) | Pre-production checklist |
| [kubernetes/K8S-W3-DEPLOYMENT-PLAN.md](kubernetes/K8S-W3-DEPLOYMENT-PLAN.md) | Worker node deployment plan |
| [TODO-configmap-migration.md](TODO-configmap-migration.md) | ConfigMap migration tracking |

---

## Platform Components

```
Infrastructure Layer:
├── Proxmox (Terraform)      - VM provisioning
├── Kubernetes (Kubespray)   - Container orchestration
└── AWS (Terraform)          - Hybrid cloud extension

Configuration Layer:
├── Ansible                  - Non-K8s host configuration
├── Flux                     - K8s GitOps deployments
└── Helm                     - Complex K8s applications

Observability:
├── Prometheus               - Metrics collection
├── Grafana                  - Visualization
├── Alertmanager             - Alert routing
└── node_exporter            - Host metrics

Data Layer:
├── Ceph (rook-ceph)         - K8s persistent storage
├── Velero                   - Backup/restore
└── SOPS                     - Secret encryption
```
