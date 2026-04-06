# homelab-infra

Single source of truth for:
- Proxmox provisioning (Terraform)
- Kubernetes build (Kubespray inventory + docs)
- Kubernetes platform manifests/values (Traefik, MetalLB, Monitoring, Storage)
- AWS infrastructure (VPN, DNS, ALB, External Monitoring)

## Layout

```
infra/terraform/        Terraform projects (Proxmox, AWS)
infra/kubespray/        Kubespray submodule + inventories
infra/ansible/          Ansible playbooks for infrastructure
platform/kubernetes/    Helm values + manifests applied to cluster
clusters/wind/          Flux GitOps configuration
docs/                   Architecture + runbooks
```

## GitOps Management

This repository uses [Flux](https://fluxcd.io/) for GitOps-based Kubernetes management.

### Flux-Managed Components

**Helm Releases** (via HelmRelease CRDs):
- cert-manager - TLS certificate management
- cloudnative-pg - PostgreSQL operator
- gpu-operator - NVIDIA GPU support
- kured - Kubernetes reboot daemon
- kube-prometheus-stack - Monitoring (Prometheus, Grafana, Alertmanager)
- prometheus-pushgateway - Metrics push endpoint
- traefik - Ingress controller
- velero - Backup and restore

**Kustomizations** (direct manifests):
- metallb - Load balancer
- technitium - DNS server
- ceph-csi - Storage driver
- auto-remediation - Automatic pod recovery
- home-automation - Home Assistant
- plex - Media server
- ollama - LLM services
- And more...

### Flux Reconciliation

Changes pushed to `main` branch are automatically applied:
```bash
# Check Flux status
flux get kustomizations
flux get helmreleases -A

# Force reconciliation
flux reconcile kustomization flux-system --with-source
```

## Quick Links

- [Architecture Overview](docs/architecture/overview.md)
- [Network Architecture](docs/architecture/network.md)
- [AWS Infrastructure](docs/architecture/aws-infrastructure.md)
- [Operations Guide](docs/runbooks/operations-guide.md)
