# homelab-infra

Single source of truth for:
- Proxmox provisioning (Terraform)
- Kubernetes build (Kubespray inventory + docs)
- Kubernetes platform manifests/values (Traefik, MetalLB, Monitoring, Storage)

## Layout
- infra/terraform/        Terraform projects (Proxmox, AWS)
- infra/ansible/          Kubespray submodule + inventories/playbooks
- platform/kubernetes/    Helm values + manifests applied to the cluster
- docs/                   Architecture + runbooks
