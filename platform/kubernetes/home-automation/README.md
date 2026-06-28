# Home Assistant

Home Assistant deployment with multi-VLAN support for device discovery.

**Deployment Method**: This application is managed via **Flux GitOps**. Configuration changes are deployed automatically from git commits.

## Overview

- **Container**: Official Home Assistant container (ghcr.io/home-assistant/home-assistant:stable)
- **Storage**: Ceph RBD PVC for config persistence
- **Networking**: Multus CNI for multi-VLAN access
- **Ingress**: Traefik with automatic SSL via Cloudflare
- **GitOps**: Configuration managed via ConfigMap generator (see [Flux Overview](../../../docs/setup/gitops/flux-overview.md))

## Architecture

### Network Configuration

Home Assistant has access to multiple VLANs for device discovery:

| Interface | VLAN | Network | IP Address | Purpose |
|-----------|------|---------|------------|---------|
| eth0 | - | Cluster network | Dynamic | Primary cluster connectivity |
| net1 | 202 | 10.10.202.0/24 | 10.10.202.25 | Client devices |
| net2 | 204 | 10.10.204.0/24 | 10.10.204.25 | IoT devices |
| net3 | 205 | 10.10.205.0/24 | 10.10.205.25 | Security devices (cameras, etc.) |

### GitOps Configuration Management

- **configuration.yaml**: Managed via Git → ConfigMap → mounted read-only in pod
- **automations.yaml, scripts.yaml, scenes.yaml**: Managed via Home Assistant UI → stored on PVC
- **Other data** (.storage/, database): Stored on PVC

```
┌──────────────────┐
│   Git Repository │  ← You edit configuration.yaml here
│  (configuration)  │
└────────┬─────────┘
         │
         │ (1) Git push
         ↓
┌──────────────────┐
│  Flux GitOps     │  ← Detects changes
│                  │
└────────┬─────────┘
         │
         │ (2) Kustomize generates ConfigMap with hash
         ↓
┌──────────────────────────┐
│ ConfigMap                │
│ home-assistant-config-   │
│ abc123xyz (new hash)     │
└────────┬─────────────────┘
         │
         │ (3) Deployment sees new ConfigMap → Rolling restart
         ↓
┌──────────────────┐
│ Home Assistant   │  ← Loads new configuration
│ Pod              │
└──────────────────┘
```

## Prerequisites

### 1. Multus CNI Installation

**Note:** Multus is managed by Kubespray. It will be installed automatically when you run the Kubespray playbook with `kube_network_plugin_multus: true` enabled in the inventory configuration.

See `infra/ansible/KUBESPRAY_MIGRATION.md` for deployment steps.

### 2. Node Network Configuration

Each Kubernetes node has the Multus VLAN parent interfaces
(`enp6s19/20/21`) baked into the Packer template via netplan
(`/etc/netplan/51-vlan-interfaces.yaml`). See
[`docs/reference/node-vlan-setup.md`](../../../docs/reference/node-vlan-setup.md)
for the per-node summary, and
[`docs/runbooks/vlan-interfaces-netplan.md`](../../../docs/runbooks/vlan-interfaces-netplan.md)
for emergency recovery.

Applies to all workers: k8s-w1, k8s-w2, k8s-w3, k8s-w4, k8s-gpu1.

### 3. Terraform Updates

Add additional network adapters to each VM:
```bash
cd infra/terraform/proxmox/k8s-vms
terraform plan
terraform apply
```

This will add 3 additional NICs to each node (VLANs 202, 204, 205).

### 4. Apply Multus NetworkAttachmentDefinitions

```bash
kubectl apply -f platform/kubernetes/multus/network-attachment-definitions/
```

## Deployment

### GitOps Deployment (Recommended)

This application is managed by Flux. Configuration changes are made via git:

#### 1. Edit Configuration Locally

```bash
# Edit the configuration file
vim platform/kubernetes/home-automation/configuration.yaml

# Make your changes (add integrations, customize settings, etc.)
```

#### 2. Test the Kustomization (Optional)

```bash
kubectl kustomize platform/kubernetes/home-automation
```

#### 3. Commit and Push

```bash
git add platform/kubernetes/home-automation/configuration.yaml
git commit -m "home-automation: add new automation"
git push
```

#### 4. Flux Automatically Syncs

Flux watches the git repository and will:
1. Detect the configuration.yaml change
2. Rebuild the ConfigMap with a new hash (e.g., `home-assistant-config-abc123`)
3. Update the deployment to use the new ConfigMap
4. Trigger a rolling restart of Home Assistant pods
5. Home Assistant loads the new configuration

**Timeline**: Changes typically apply within 1-5 minutes of pushing to git.

#### 5. Force Manual Sync (if needed)

To force an immediate sync instead of waiting (no flux CLI on the hosts — CLAUDE.md §3):

```bash
kubectl annotate -n flux-system gitrepository/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
kubectl annotate -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite

# Watch the rollout
kubectl rollout status deployment/home-assistant -n home-automation
```

See [Making Changes to GitOps Apps](../../../docs/setup/gitops/making-changes.md) for detailed workflows.

### Manual Deployment (Not Recommended)

If you need to bypass GitOps (changes will be reverted by Flux):

```bash
# Deploy via kustomize
kubectl apply -k platform/kubernetes/home-automation/

# Or deploy individual files:
kubectl apply -f namespace.yaml
kubectl apply -f pvc.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
kubectl apply -f ingressroute.yaml
```

**Note**: Manual changes will be reverted by Flux on the next reconciliation. Always update git for persistent changes.

## Access

- **External URL**: https://ha.wind.etherport.net (via Traefik with SSL)
- **Direct VLAN access**:
  - 10.10.202.25:8123 (from client VLAN)
  - 10.10.204.25:8123 (from IoT VLAN)
  - 10.10.205.25:8123 (from security VLAN)

## Making Changes

### Update Home Assistant Configuration

```bash
# 1. Edit configuration.yaml
vim platform/kubernetes/home-automation/configuration.yaml

# 2. Add/modify configuration
# Example: Add new integration
homeassistant:
  name: Home
  latitude: 37.7749
  longitude: -122.4194

# 3. Commit and push
git add platform/kubernetes/home-automation/configuration.yaml
git commit -m "home-automation: add location configuration"
git push

# 4. Force reconciliation (or wait 1-5 minutes)
kubectl annotate -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite

# 5. Verify pod restart
kubectl get pods -n home-automation -w

# 6. Check logs for configuration reload
kubectl logs -n home-automation -l app=home-assistant --tail=100
```

### Update Container Image

```bash
# Edit deployment
vim platform/kubernetes/home-automation/deployment.yaml

# Change image version
image: ghcr.io/home-assistant/home-assistant:2024.1.0

# Commit and push
git add platform/kubernetes/home-automation/deployment.yaml
git commit -m "home-automation: upgrade to 2024.1.0"
git push

# Force reconciliation
kubectl annotate -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite

# Watch rollout
kubectl rollout status deployment/home-assistant -n home-automation
```

## Verification

### Check Deployment

```bash
# Check pod status
kubectl get pods -n home-automation

# Verify network interfaces
kubectl exec -n home-automation -it <pod-name> -- ip addr

# Should see:
# - eth0: Cluster network (Cilium)
# - net1: 10.10.202.25/24
# - net2: 10.10.204.25/24
# - net3: 10.10.205.25/24
```

### Verify Configuration

```bash
# Check current ConfigMap (should have hash suffix)
kubectl get configmap -n home-automation | grep home-assistant-config

# View ConfigMap contents
kubectl get configmap -n home-automation -l app=home-assistant -o yaml

# Verify deployment is using the ConfigMap
kubectl describe deployment home-assistant -n home-automation | grep ConfigMap
```

### Check Logs

```bash
# View Home Assistant logs
kubectl logs -n home-automation -l app=home-assistant -f

# Check for configuration errors
kubectl logs -n home-automation -l app=home-assistant --tail=100 | grep -i error
```

## Troubleshooting

### Configuration Changes Not Applying

**Symptom**: Edited configuration.yaml in git but changes don't appear in Home Assistant.

**Steps**:
1. Check Flux reconciliation status:
   ```bash
   kubectl get gitrepositories -n flux-system
   kubectl get kustomizations -n flux-system
   ```

2. Look for errors in Flux:
   ```bash
   kubectl describe kustomization flux-system -n flux-system
   ```

3. Force reconciliation:
   ```bash
   kubectl annotate -n flux-system gitrepository/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
   kubectl annotate -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
   ```

4. Verify new ConfigMap was created:
   ```bash
   kubectl get configmap -n home-automation | grep home-assistant-config
   # Should see a new hash suffix
   ```

5. Check pod is using new ConfigMap:
   ```bash
   kubectl describe pod -n home-automation -l app=home-assistant | grep ConfigMap
   ```

### Pod Not Restarting After Configuration Change

**Symptom**: ConfigMap updated but pod still running with old configuration.

**Solution**: The ConfigMap generator should create a new hash, triggering a restart. If not:

```bash
# Force restart
kubectl rollout restart deployment/home-assistant -n home-automation

# Watch restart
kubectl rollout status deployment/home-assistant -n home-automation
```

### Network Interfaces Not Available

**Symptom**: Home Assistant can't discover devices on VLANs.

**Check**:
```bash
# Verify VLAN interfaces in pod
kubectl exec -n home-automation -it <pod-name> -- ip addr

# Check Multus NetworkAttachmentDefinitions
kubectl get network-attachment-definitions -n home-automation

# Verify node VLAN configuration (Multus parent interfaces, node side)
ssh k8s-w1 ip -br link show enp6s19 enp6s20 enp6s21
# In-pod NICs are net1/net2/net3 (not eth1-3); eth0 is the cluster network
```

### Home Assistant Configuration Invalid

**Symptom**: Home Assistant won't start due to configuration errors.

**Check**:
```bash
# View startup logs
kubectl logs -n home-automation -l app=home-assistant --tail=200

# Look for configuration validation errors
kubectl logs -n home-automation -l app=home-assistant | grep -i "invalid\|error"
```

**Fix**:
1. Revert the bad configuration in git
2. Push the revert
3. Force Flux reconciliation
4. Watch for pod to restart with working configuration

## Important Notes

### Secrets Management

⚠️ **Secrets**: The configuration.yaml currently contains secrets (passwords, API keys). Consider:
- Moving secrets to Kubernetes Secrets or SOPS-encrypted secrets
- Using environment variables for sensitive data
- Never commit real secrets to public repositories

See [SOPS Setup](../../../docs/setup/secrets/SOPS-SETUP.md) for encrypted secret management.

### UI-Managed Files

✅ **UI-Managed Files**: Files like automations.yaml, scripts.yaml, and scenes.yaml are managed through the Home Assistant UI and stored on the PVC. Don't try to manage these in git - only configuration.yaml is GitOps-managed.

### Pod Restarts

✅ **Pod Restart**: Changes to configuration.yaml require a pod restart. This happens automatically when using Kustomize's ConfigMap generator, as the ConfigMap gets a new hash suffix.

## Files

- `configuration.yaml` - Home Assistant configuration (GitOps-managed via ConfigMap)
- `deployment.yaml` - Kubernetes Deployment with Multus network attachments
- `service.yaml` - ClusterIP service
- `ingressroute.yaml` - Traefik IngressRoute for external access
- `pvc.yaml` - Ceph RBD PVC for persistent storage
- `namespace.yaml` - Namespace definition
- `kustomization.yaml` - Kustomize configuration with ConfigMap generator

## Related Documentation

- [Flux GitOps Overview](../../../docs/setup/gitops/flux-overview.md)
- [Making Changes to GitOps Apps](../../../docs/setup/gitops/making-changes.md)
- [SOPS Setup](../../../docs/setup/secrets/SOPS-SETUP.md)
- [Multus CNI](../multus/README.md)
- [Node VLAN Setup](../../../docs/reference/node-vlan-setup.md)
- [VLAN netplan runbook](../../../docs/runbooks/vlan-interfaces-netplan.md)
