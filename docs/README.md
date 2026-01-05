# Homelab Infrastructure Documentation

## Quick Start

**Start here:** [PLATFORM-MANAGEMENT.md](PLATFORM-MANAGEMENT.md) - Centralized guide covering monitoring, updates, deployments, and operations across the entire platform.

## Documentation Index

### Operations
| Document | Description |
|----------|-------------|
| [PLATFORM-MANAGEMENT.md](PLATFORM-MANAGEMENT.md) | **Central ops guide** - monitoring, updates, deployments |
| [runbooks/operations-guide.md](runbooks/operations-guide.md) | Quick command reference for standalone management |
| [NODE-UPDATES.md](NODE-UPDATES.md) | OS and Kubernetes update strategies |

### Architecture
| Document | Description |
|----------|-------------|
| [architecture/overview.md](architecture/overview.md) | High-level infrastructure design |
| [architecture/network.md](architecture/network.md) | Network topology and VLANs |
| [architecture/vpn-wireguard.md](architecture/vpn-wireguard.md) | Site-to-site VPN configuration |
| [architecture/aws-infrastructure.md](architecture/aws-infrastructure.md) | AWS hybrid cloud components |

### GitOps & Deployment
| Document | Description |
|----------|-------------|
| [gitops/flux-overview.md](gitops/flux-overview.md) | Flux GitOps workflow and patterns |
| [SOPS-SETUP.md](SOPS-SETUP.md) | Secret encryption with SOPS + age |
| [VERSIONING-STRATEGY.md](VERSIONING-STRATEGY.md) | Version management approach |

### Infrastructure as Code
| Document | Description |
|----------|-------------|
| [terraform/proxmox-k8s-vms.md](terraform/proxmox-k8s-vms.md) | Proxmox VM provisioning |
| [terraform/remote-state-backend.md](terraform/remote-state-backend.md) | Terraform state in S3 |

### Runbooks
| Document | Description |
|----------|-------------|
| [runbooks/kubernetes-ops.md](runbooks/kubernetes-ops.md) | K8s operational procedures |
| [runbooks/dns-resolution-issues.md](runbooks/dns-resolution-issues.md) | DNS troubleshooting |
| [runbooks/auto-remediation/](runbooks/auto-remediation/) | Automated issue resolution |

### Tooling
| Document | Description |
|----------|-------------|
| [1PASSWORD-CLI.md](1PASSWORD-CLI.md) | 1Password CLI usage |
| [PRODUCTION-READINESS-CHECKLIST.md](PRODUCTION-READINESS-CHECKLIST.md) | Pre-production checklist |

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
