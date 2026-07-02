# Operations Guide

Quick reference for managing the homelab infrastructure without Claude Code.

## Prerequisites

### Required Tools

```bash
# macOS (via Homebrew)
# NB: no `flux` CLI — this homelab reconciles Flux via kubectl annotations
# (reconcile.fluxcd.io/requestedAt), not the flux CLI. See CLAUDE.md §3.
brew install ansible terraform kubectl helm sops age 1password-cli

# Verify installations
ansible --version
terraform --version
kubectl version --client
helm version
sops --version
op --version
```

### SSH Access

The Ubuntu fleet is **cert-only** (M76): the devbox/CI mint a short-lived user
cert (renew-loop → `~/.ssh/id_homelab_cert`, presented automatically via
ssh-config). Just `ssh ubuntu@<host>` — no `-i`/key to load. Break-glass = PVE
console + IPMI. See CLAUDE.md §4.

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
cd ~/code/infra/infra/ansible
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

`infra/ansible/playbooks/`:

| Playbook | Purpose | Typical target |
|----------|---------|----------------|
| base.yml | System config (NTP, upgrades, SSH, swap, node_exporter, cw-agent) | all standalone VMs |
| wireguard.yml | WireGuard config (server + keepalived for vpn-local) | vpn_servers |
| technitium.yml | Technitium DNS install + cluster bootstrap | dns_servers |
| swap.yml | Provision swap files on standalone VMs | dns_servers + vpn_servers |
| cloudwatch-agent.yml | Install AWS cw-agent on the edge box (vpn-aws) | aws hosts |
| etcd-backup.yml | Install systemd timer for daily etcd snapshots | k8s_cp |
| etcd-defrag.yml | Install weekly staggered etcd defrag timer (H41 — reclaims boltdb fragmentation) | k8s_cp |
| proxmox.yml + proxmox-setup.yml | PVE host management (root-over-key, see `pve-ansible-model`) | proxmox_hosts |
| pve-sshd.yml | Manage `/etc/ssh/sshd_config.d/` on PVE (PerSourcePenalty fix) | proxmox_hosts |
| pve-network.yml | Manage PVE bridges + VLANs (idempotent netplan-equivalent) | proxmox_hosts |
| ceph-msgr2.yml | Enable + verify msgr2 (v2 protocol) on Ceph mons | proxmox_hosts |
| gh-runner.yml | Bootstrap + maintain the self-hosted GH Actions runner VM | gh_runner |
| ipmi-monitoring.yml | ipmi_exporter + ipmievd setup on PVE (M40) | proxmox_hosts |
| tailscale.yml | Tailscale install + auth on standalone VMs | all standalone VMs |
| udm-firewall.yml | UDM zone-based firewall + DNS policy (v2 API — this is the source of truth for zone policies; the unifi TF provider only covers networks/reservations/port-forwards). Always `--check --diff` first | udm |
| k8s-node-fixes.yml | OS-level fixes for K8s nodes (NIC tunables, sysctl) | k8s_all |
| ceph/ | Ceph operator manifests + helpers (legacy, mostly superseded by external ceph on PVE) | n/a |

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

> **Terraform is CI-only** (M82): the devbox holds no standing AWS/PVE creds —
> stacks run via GitHub Actions (AWS via OIDC; proxmox/unifi/cloudflare on the
> self-hosted runner). For rare local debug, re-render creds on demand
> (`scripts/render-aws-credentials.sh`, `scripts/tf-proxmox.sh`). See CLAUDE.md §4.

### Working Directory
```bash
cd ~/code/infra/infra/terraform/proxmox
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
cd ~/code/infra/infra/terraform/proxmox/k8s-vms

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
# Locking is S3-native (use_lockfile=true) — no DynamoDB

# Force unlock if stuck
terraform force-unlock <LOCK_ID>
```

## Kubernetes Operations

Standard kubectl applies (`get`/`describe`/`logs [--previous|-f]`/`exec -it`/
`port-forward`/`scale`/`rollout {status,undo,restart}`/`apply`/`delete`). The
cluster is 8 nodes (`kubectl get nodes -o wide`). Note: most workloads are
**Flux-managed** — to change a deployment, edit the manifest under
`platform/kubernetes/` and reconcile, don't `kubectl edit` live (it gets reverted).

## Flux GitOps Operations

### Check Flux Status

```bash
# Overall status (no flux CLI on the hosts — query the CRs directly)
kubectl get gitrepository,kustomization,helmrelease,imagerepository,imagepolicy,imageupdateautomation -A

# Kustomizations
kubectl get kustomizations -A

# Helm releases
kubectl get helmrelease -A

# Sources
kubectl get gitrepository,helmrepository,ocirepository -A
```

### Reconcile Resources

```bash
# Force reconcile kustomization (annotate the source first, then the kustomization)
kubectl annotate --overwrite -n flux-system gitrepository/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
kubectl annotate --overwrite -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"

# Force reconcile helm release
kubectl annotate --overwrite -n <namespace> helmrelease/<name> reconcile.fluxcd.io/requestedAt="$(date +%s)"

# Suspend/resume
kubectl patch kustomization/<name> -n flux-system --type=merge -p '{"spec":{"suspend":true}}'
kubectl patch kustomization/<name> -n flux-system --type=merge -p '{"spec":{"suspend":false}}'
```

### Troubleshooting Flux

```bash
# Check Flux controllers
kubectl get pods -n flux-system

# Flux logs (per-controller — no flux CLI on the hosts)
kubectl logs -n flux-system deploy/source-controller
kubectl logs -n flux-system deploy/kustomize-controller
kubectl logs -n flux-system deploy/helm-controller

# Specific controller logs
kubectl logs -n flux-system deployment/source-controller
kubectl logs -n flux-system deployment/kustomize-controller
```

## DNS (Technitium) Operations

### Web UI Access

- Primary: https://dns.wind.etherport.net:5380
- Fallback: http://10.10.201.6:5380
- AWS edge box (vpn-aws): http://10.10.100.10:5380

Credentials: See 1Password "Technitium DNS"

### CLI Testing

```bash
# Test DNS resolution
dig @10.10.201.71 k8s-cp1.wind.etherport.net
dig @10.10.201.6 google.com

# Check all cluster nodes
for ip in 10.10.201.71 10.10.201.72 10.10.201.6 10.10.100.10; do
  echo "$ip: $(dig @$ip k8s-cp1.wind.etherport.net +short)"
done
```

## VPN (WireGuard) Operations

> The primary site-to-site WireGuard runs as a Kubernetes pod
> (`wireguard/wireguard` deployment) with `vpn-local` as the VRRP backup.
> "Restart WireGuard" on the K8s side means restarting that pod, not a
> systemd unit. SSH to the standalone VMs is cert-only (`ssh ubuntu@<host>`).

### Check Status

```bash
# K8s WireGuard (primary)
kubectl get pods -n wireguard
kubectl exec -n wireguard deployment/wireguard -c wireguard -- wg show wg0

# Local VPN server (backup) — cert-only SSH
ssh ubuntu@vpn-local.wind.etherport.net "sudo wg show"

# AWS VPN server
ssh ubuntu@10.10.100.10 "sudo wg show"
```

### Restart WireGuard

```bash
# K8s (primary) - restart the pod, not a systemd unit
kubectl rollout restart deployment wireguard -n wireguard

# On vpn-local (backup VM - cert-only SSH)
ssh ubuntu@vpn-local.wind.etherport.net "sudo systemctl restart wg-quick@wg0"

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

Generic debugging is standard: SSH `-vvv` (cert auth — see SSH Access above),
`ansible-playbook --syntax-check/--list-tasks/-vvv`, `kubectl describe
node/pod/pvc` + `kubectl get events`. Homelab-specific gotchas (4-layer
connectivity gating, Cilium netpol tiers, Ceph-over-firewall) are in CLAUDE.md §5.

### Flux Issues

```bash
# Check why resource not deploying
kubectl get kustomization <name> -n flux-system
kubectl describe kustomization <name> -n flux-system

# Check source fetch
kubectl get gitrepository flux-system -n flux-system
```

## Monitoring & Alerting

### Grafana Access

- **URL**: https://grafana.wind.etherport.net
- **Credentials**: See `platform/kubernetes/monitoring/grafana-admin-secret.sops.yaml`

### Check Alert Status

```bash
# Get active alerts from Alertmanager
kubectl exec -n monitoring alertmanager-monitoring-kube-prometheus-alertmanager-0 \
  -c alertmanager -- wget -q -O- http://localhost:9093/api/v2/alerts | python3 -m json.tool

# Check Prometheus rules are loaded
kubectl get prometheusrule -n monitoring

# View PrometheusRule details
kubectl describe prometheusrule comprehensive-service-alerts -n monitoring
```

### Email Notifications

Alerts are sent via AWS SES to `graham.m.smith@me.com`. Configuration:

- **AlertmanagerConfig**: `platform/kubernetes/monitoring/03-alertmanager-config.yaml`
- **SMTP Secret**: `platform/kubernetes/monitoring/alertmanager-secret.sops.yaml`
- **IAM User**: `alertmanager-ses-smtp` (SES SMTP credentials)

```bash
# Test email alert
kubectl exec -n monitoring alertmanager-monitoring-kube-prometheus-alertmanager-0 \
  -c alertmanager -- wget -q -O- \
  --header='Content-Type: application/json' \
  --post-data='[{"labels":{"alertname":"TestAlert","severity":"warning","namespace":"monitoring"},"annotations":{"summary":"Test alert"}}]' \
  http://localhost:9093/api/v2/alerts

# Check Alertmanager logs
kubectl logs -n monitoring alertmanager-monitoring-kube-prometheus-alertmanager-0 -c alertmanager --tail=50

# Verify SMTP secret
kubectl get secret alertmanager-smtp-config -n monitoring
```

### Force Reconcile Monitoring

```bash
kubectl annotate --overwrite -n flux-system helmrelease/monitoring reconcile.fluxcd.io/requestedAt="$(date +%s)"
kubectl annotate --overwrite -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
```

## GPU Operations

### Check GPU Status

```bash
# Verify GPU node
kubectl get nodes -l nvidia.com/gpu.present=true

# Check GPU resources available
kubectl describe node k8s-gpu1 | grep -A 10 "Allocated resources"

# Check GPU operator pods
kubectl get pods -n gpu-operator-system

# Check device plugin is advertising GPUs
kubectl get node k8s-gpu1 -o jsonpath='{.status.allocatable}' | python3 -m json.tool
```

### GPU Workload Management

```bash
# Check GPU workloads
kubectl get pods -n plex
kubectl get pods -n ollama

# Scale GPU workloads (e.g., for maintenance)
kubectl scale deployment plex -n plex --replicas=0
kubectl scale deployment ollama -n ollama --replicas=0

# Restore GPU workloads
kubectl scale deployment plex -n plex --replicas=1
kubectl scale deployment ollama -n ollama --replicas=1
```

### GPU Driver Updates

The GPU Operator is configured for automatic driver upgrades with drain settings:

```bash
# Check driver daemonset status
kubectl get daemonset nvidia-driver-daemonset -n gpu-operator-system

# Check driver pod logs
kubectl logs -n gpu-operator-system -l app=nvidia-driver-daemonset --tail=50

# Force driver reinstall (if needed)
kubectl rollout restart daemonset nvidia-driver-daemonset -n gpu-operator-system
```

### GPU Troubleshooting

```bash
# If GPU workloads fail after driver update
kubectl get events -n plex --sort-by=.metadata.creationTimestamp | tail -20
kubectl describe pod -n plex -l app=plex

# Check if driver is ready
kubectl exec -n gpu-operator-system -l app=nvidia-driver-daemonset -- nvidia-smi

# Restart GPU operator
kubectl annotate --overwrite -n flux-system helmrelease/gpu-operator reconcile.fluxcd.io/requestedAt="$(date +%s)"
```

## Platform Features (Quick Reference)

| Feature | Where | Notes |
|---------|-------|-------|
| Hardware watchdog (i6300esb) | Per-VM, see `docs/runbooks/vm-watchdog.md` | ⚠️ **NOT WORKING — blocked (M91):** node kernel lacks the `i6300esb` module; has never armed. Don't rely on it |
| CNPG HA | `platform/kubernetes/cnpg/` | `instances: 3` is the standard; primary + 2 sync replicas |
| Velero schedules | `platform/kubernetes/backups/velero/schedules/` | Per-namespace schedules, git-managed via kustomization |
| Post-bootstrap script | `infra/kubespray/post-bootstrap.sh` | Run once after a fresh cluster bring-up; restores Multus NADs, applies cluster-only kustomizations |

## Emergency Procedures

### Cluster Recovery

1. Check control plane: `ssh ubuntu@k8s-cp1.wind.etherport.net`
   (cp2/cp3 at .51/.52 — pick any healthy member)
2. Check kubelet: `systemctl status kubelet`
3. Check etcd: `kubectl get pods -n kube-system | grep etcd`

### VPN Down

If site-to-site VPN is down:
1. Check K8s WireGuard (primary): `kubectl get pods -n wireguard`
2. Check vpn-local (VRRP backup): `ssh ubuntu@10.10.201.15 "sudo wg show"`
3. Check AWS VPN: Access via AWS console if needed
4. Restart WireGuard on the appropriate side (pod restart for K8s; systemd
   for vpn-local/vpn-aws)

### DNS Issues

If DNS is failing:
1. Check cluster DNS: `dig @10.10.201.71 google.com`
2. Check fallback: `dig @10.10.201.6 google.com`
3. Check AWS edge box: `dig @10.10.100.10 google.com` (via VPN)
4. Access Technitium web UI to check cluster status
