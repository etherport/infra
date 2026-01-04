# Operations Guide

Quick reference for managing the homelab infrastructure without Claude Code.

## Prerequisites

### Required Tools

```bash
# macOS (via Homebrew)
brew install ansible terraform kubectl helm flux sops age 1password-cli

# Verify installations
ansible --version
terraform --version
kubectl version --client
helm version
flux --version
sops --version
op --version
```

### SSH Key Setup

Ensure your SSH key is loaded:
```bash
ssh-add -l                    # List loaded keys
ssh-add ~/.ssh/id_ed25519     # Load key if needed
```

### Kubeconfig

```bash
export KUBECONFIG=~/.kube/config
kubectl cluster-info          # Verify connection
```

### AWS CLI (for AWS resources)

```bash
aws configure --profile homelab
aws --profile homelab sts get-caller-identity
```

## Directory Structure

```
homelab-infra/
├── infra/
│   ├── ansible/
│   │   ├── inventory/wind/    # Local hosts
│   │   ├── inventory/aws/     # AWS hosts
│   │   └── playbooks/         # Ansible playbooks
│   └── terraform/
│       └── proxmox/           # Proxmox Terraform configs
├── platform/kubernetes/       # K8s manifests (Flux managed)
└── docs/                      # Documentation
```

## Ansible Operations

### Working Directory
```bash
cd ~/Projects/homelab-infra/infra/ansible
```

### Inventory Check
```bash
# List all hosts
ansible-inventory -i inventory/wind/inventory.ini -i inventory/aws/inventory.ini --list

# Ping all hosts
ansible all -i inventory/wind/inventory.ini -i inventory/aws/inventory.ini -m ping

# Ping specific group
ansible dns_servers -i inventory/wind/inventory.ini -i inventory/aws/inventory.ini -m ping
```

### Available Playbooks

| Playbook | Purpose | Target Hosts |
|----------|---------|--------------|
| base.yml | System config (NTP, upgrades, SSH) | dns_servers, vpn_servers |
| wireguard.yml | WireGuard VPN configuration | vpn_servers |
| technitium.yml | Technitium DNS Server | dns_servers |

### Running Playbooks

```bash
# Dry run (check mode)
ansible-playbook -i inventory/wind/inventory.ini -i inventory/aws/inventory.ini \
  playbooks/base.yml --limit dns_servers,vpn_servers --check --diff

# Apply changes
ansible-playbook -i inventory/wind/inventory.ini -i inventory/aws/inventory.ini \
  playbooks/base.yml --limit dns_servers,vpn_servers

# Run on specific host
ansible-playbook -i inventory/wind/inventory.ini playbooks/technitium.yml --limit dns-fallback

# Run on AWS hosts only
ansible-playbook -i inventory/aws/inventory.ini playbooks/base.yml
```

### Ad-hoc Commands

```bash
# Check uptime
ansible all -i inventory/wind/inventory.ini -a "uptime"

# Check disk space
ansible dns_servers -i inventory/wind/inventory.ini -a "df -h"

# Restart a service
ansible dns-fallback -i inventory/wind/inventory.ini -b -m systemd -a "name=technitium state=restarted"

# Run apt update
ansible all -i inventory/wind/inventory.ini -b -m apt -a "update_cache=yes"
```

## Terraform Operations

### Working Directory
```bash
cd ~/Projects/homelab-infra/infra/terraform/proxmox
```

### Common Commands

```bash
# Initialize (first time or after provider changes)
terraform init

# Plan changes
terraform plan

# Apply changes
terraform apply

# Show current state
terraform show

# List resources
terraform state list

# Import existing resource
terraform import proxmox_virtual_environment_vm.vm pve/qemu/100
```

### Proxmox VM Management

```bash
cd ~/Projects/homelab-infra/infra/terraform/proxmox/k8s-cluster

# Plan K8s node changes
terraform plan

# Apply (will prompt for confirmation)
terraform apply

# Destroy specific resource
terraform destroy -target=proxmox_virtual_environment_vm.k8s_workers["k8s-w3"]
```

### State Management

```bash
# State is stored in S3 (see backend.tf)
# Lock table: homelab-terraform-locks (DynamoDB)

# Force unlock if stuck
terraform force-unlock <LOCK_ID>
```

## Kubernetes Operations

### Cluster Access

```bash
# Get cluster info
kubectl cluster-info

# Get nodes
kubectl get nodes -o wide

# Get all pods
kubectl get pods -A

# Get events (recent)
kubectl get events -A --sort-by=.metadata.creationTimestamp | tail -50
```

### Namespace Operations

```bash
# List namespaces
kubectl get ns

# Switch context namespace
kubectl config set-context --current --namespace=dns

# Get resources in namespace
kubectl get all -n dns
```

### Pod Troubleshooting

```bash
# Describe pod
kubectl describe pod <pod-name> -n <namespace>

# Get logs
kubectl logs <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace> --previous  # Previous container
kubectl logs -f <pod-name> -n <namespace>          # Follow logs

# Exec into pod
kubectl exec -it <pod-name> -n <namespace> -- /bin/bash
kubectl exec -it <pod-name> -n <namespace> -- /bin/sh

# Port forward
kubectl port-forward svc/<service-name> <local-port>:<service-port> -n <namespace>
```

### Deployment Operations

```bash
# Scale deployment
kubectl scale deployment <name> --replicas=3 -n <namespace>

# Rollout status
kubectl rollout status deployment/<name> -n <namespace>

# Rollback
kubectl rollout undo deployment/<name> -n <namespace>

# Restart deployment (rolling restart)
kubectl rollout restart deployment/<name> -n <namespace>
```

### Resource Management

```bash
# Apply manifest
kubectl apply -f <file.yaml>

# Delete resource
kubectl delete -f <file.yaml>

# Get YAML of resource
kubectl get <resource> <name> -n <namespace> -o yaml
```

## Flux GitOps Operations

### Check Flux Status

```bash
# Overall status
flux get all -A

# Kustomizations
flux get kustomizations -A

# Helm releases
flux get helmreleases -A

# Sources
flux get sources all -A
```

### Reconcile Resources

```bash
# Force reconcile kustomization
flux reconcile kustomization flux-system --with-source

# Force reconcile helm release
flux reconcile helmrelease <name> -n <namespace>

# Suspend/resume
flux suspend kustomization <name>
flux resume kustomization <name>
```

### Troubleshooting Flux

```bash
# Check Flux controllers
kubectl get pods -n flux-system

# Flux logs
flux logs --all-namespaces

# Specific controller logs
kubectl logs -n flux-system deployment/source-controller
kubectl logs -n flux-system deployment/kustomize-controller
```

## DNS (Technitium) Operations

### Web UI Access

- Primary: https://dns.wind.etherport.net:5380
- Fallback: http://10.10.201.6:5380
- AWS: http://10.10.100.5:5380

Credentials: See 1Password "Technitium DNS"

### CLI Testing

```bash
# Test DNS resolution
dig @10.10.201.71 k8s-cp1.wind.etherport.net
dig @10.10.201.6 google.com

# Check all cluster nodes
for ip in 10.10.201.71 10.10.201.72 10.10.201.6 10.10.100.5; do
  echo "$ip: $(dig @$ip k8s-cp1.wind.etherport.net +short)"
done
```

## VPN (WireGuard) Operations

### Check Status

```bash
# Local VPN server
ssh graham@vpn-local.wind.etherport.net "sudo wg show"

# AWS VPN server
ssh ubuntu@10.10.100.10 "sudo wg show"
```

### Restart WireGuard

```bash
# On vpn-local
ssh graham@vpn-local.wind.etherport.net "sudo systemctl restart wg-quick@wg0"

# On vpn-aws
ssh ubuntu@10.10.100.10 "sudo systemctl restart wg-quick@wg0 wg-quick@wg1"
```

## Secrets Management (SOPS)

### Decrypt Secrets

```bash
# Decrypt and view
sops -d platform/kubernetes/technitium/05-secret.sops.yaml

# Edit in place
sops platform/kubernetes/technitium/05-secret.sops.yaml
```

### 1Password CLI

```bash
# Sign in
eval $(op signin)

# List items
op item list

# Get specific item
op item get "Technitium DNS" --fields password
```

## Common Troubleshooting

### SSH Issues

```bash
# Too many auth failures
ssh -o IdentitiesOnly=yes user@host

# Debug connection
ssh -vvv user@host
```

### Ansible Issues

```bash
# Verbose output
ansible-playbook playbook.yml -vvv

# Check syntax
ansible-playbook playbook.yml --syntax-check

# List tasks
ansible-playbook playbook.yml --list-tasks
```

### Kubernetes Issues

```bash
# Node not ready
kubectl describe node <node-name>
kubectl get events --field-selector involvedObject.name=<node-name>

# Pod stuck pending
kubectl describe pod <pod-name> -n <namespace>
kubectl get events -n <namespace> --field-selector involvedObject.name=<pod-name>

# PVC issues
kubectl get pvc -A
kubectl describe pvc <pvc-name> -n <namespace>
```

### Flux Issues

```bash
# Check why resource not deploying
flux get kustomization <name> -n <namespace>
kubectl describe kustomization <name> -n flux-system

# Check source fetch
flux get source git flux-system
```

## Emergency Procedures

### Cluster Recovery

1. Check control plane: `ssh graham@k8s-cp1.wind.etherport.net`
2. Check kubelet: `systemctl status kubelet`
3. Check etcd: `kubectl get pods -n kube-system | grep etcd`

### VPN Down

If site-to-site VPN is down:
1. Check local VPN: `ssh graham@10.10.201.15 "sudo wg show"`
2. Check AWS VPN: Access via AWS console if needed
3. Restart WireGuard on both ends

### DNS Issues

If DNS is failing:
1. Check cluster DNS: `dig @10.10.201.71 google.com`
2. Check fallback: `dig @10.10.201.6 google.com`
3. Check AWS: `dig @10.10.100.5 google.com` (via VPN)
4. Access Technitium web UI to check cluster status
