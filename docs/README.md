# Homelab Infrastructure Documentation

Central documentation index for the homelab infrastructure project.

## Quick Start

| I want to... | Go to... |
|--------------|----------|
| Understand the platform | [runbooks/PLATFORM-MANAGEMENT.md](runbooks/PLATFORM-MANAGEMENT.md) |
| Check update status | [runbooks/UPDATE-PROCEDURES.md](runbooks/UPDATE-PROCEDURES.md) |
| Run operational commands | [runbooks/operations-guide.md](runbooks/operations-guide.md) |
| Deploy changes via GitOps | [setup/gitops/making-changes.md](setup/gitops/making-changes.md) |
| Recover from failures | [runbooks/disaster-recovery.md](runbooks/disaster-recovery.md) |

---

## Documentation Structure

```
docs/
├── runbooks/          # Day-to-day operations
├── architecture/      # System design
├── setup/             # Initial setup guides
│   ├── kubernetes/    # K8s cluster setup
│   ├── terraform/     # Infrastructure as code
│   ├── gitops/        # Flux/GitOps setup
│   └── secrets/       # SOPS/1Password setup
├── reference/         # Quick reference docs
├── guides/            # Step-by-step tutorials
└── planning/          # Temporary planning docs (delete when done)
```

---

## Runbooks (Operations)

| Document | Description |
|----------|-------------|
| [PLATFORM-MANAGEMENT.md](runbooks/PLATFORM-MANAGEMENT.md) | High-level platform overview and quick links |
| [UPDATE-PROCEDURES.md](runbooks/UPDATE-PROCEDURES.md) | All update procedures - automatic, semi-auto, manual |
| [operations-guide.md](runbooks/operations-guide.md) | Command reference for all operations |
| [kubernetes-upgrade.md](runbooks/kubernetes-upgrade.md) | Kubernetes version upgrade procedures |
| [disaster-recovery.md](runbooks/disaster-recovery.md) | Recovery procedures for failure scenarios |
| [dns-resolution-issues.md](runbooks/dns-resolution-issues.md) | DNS troubleshooting |
| [vlan-interfaces-netplan.md](runbooks/vlan-interfaces-netplan.md) | VLAN interface configuration |
| [auto-remediation/](runbooks/auto-remediation/) | Automated issue resolution system |

## Architecture

| Document | Description |
|----------|-------------|
| [overview.md](architecture/overview.md) | High-level infrastructure design |
| [network.md](architecture/network.md) | Network topology and VLANs |
| [firewall-zones.md](architecture/firewall-zones.md) | Zone-based firewall configuration |
| [vpn-wireguard.md](architecture/vpn-wireguard.md) | Site-to-site VPN configuration |
| [aws-infrastructure.md](architecture/aws-infrastructure.md) | AWS hybrid cloud components |

## Setup Guides

### Kubernetes
| Document | Description |
|----------|-------------|
| [cluster-build-kubespray.md](setup/kubernetes/cluster-build-kubespray.md) | Cluster provisioning with Kubespray |
| [addons-metallb.md](setup/kubernetes/addons-metallb.md) | MetalLB load balancer setup |
| [ingress-traefik.md](setup/kubernetes/ingress-traefik.md) | Traefik ingress configuration |
| [storage-ceph-csi.md](setup/kubernetes/storage-ceph-csi.md) | Ceph CSI storage setup |
| [monitoring-kube-prometheus-stack.md](setup/kubernetes/monitoring-kube-prometheus-stack.md) | Prometheus monitoring stack |

### Terraform
| Document | Description |
|----------|-------------|
| [proxmox-k8s-vms.md](setup/terraform/proxmox-k8s-vms.md) | Proxmox VM provisioning |
| [remote-state-backend.md](setup/terraform/remote-state-backend.md) | Terraform state in S3 |

### GitOps
| Document | Description |
|----------|-------------|
| [flux-overview.md](setup/gitops/flux-overview.md) | Flux GitOps workflow and patterns |
| [making-changes.md](setup/gitops/making-changes.md) | How to make changes via GitOps |
| [repo-workflow.md](setup/gitops/repo-workflow.md) | Git repository workflow |

### Secrets
| Document | Description |
|----------|-------------|
| [SOPS-SETUP.md](setup/secrets/SOPS-SETUP.md) | Secret encryption with SOPS + age |
| [1PASSWORD-CLI.md](setup/secrets/1PASSWORD-CLI.md) | 1Password CLI integration |

## Reference

| Document | Description |
|----------|-------------|
| [kubectl-cheatsheet.md](reference/kubectl-cheatsheet.md) | kubectl command reference |
| [kustomize-patterns.md](reference/kustomize-patterns.md) | Kustomize patterns and examples |
| [node-vlan-setup.md](reference/node-vlan-setup.md) | Node VLAN configuration reference |

## Guides

| Document | Description |
|----------|-------------|
| [localtuya/](guides/localtuya/) | LocalTuya setup for IoT devices |

## Planning (Temporary)

*These docs will be deleted once implemented.*

| Document | Description |
|----------|-------------|
| [PRODUCTION-READINESS-CHECKLIST.md](planning/PRODUCTION-READINESS-CHECKLIST.md) | Pre-production checklist |
| [K8S-W3-DEPLOYMENT-PLAN.md](planning/K8S-W3-DEPLOYMENT-PLAN.md) | Worker node deployment plan |
| [TODO-configmap-migration.md](planning/TODO-configmap-migration.md) | ConfigMap migration tracking |
| [VERSIONING-STRATEGY.md](planning/VERSIONING-STRATEGY.md) | Container image versioning approach |
| [sops-vs-ansible-vault.md](planning/sops-vs-ansible-vault.md) | SOPS vs Ansible-Vault comparison |

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
