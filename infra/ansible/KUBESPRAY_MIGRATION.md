# Kubespray Configuration Migration

## Overview

This document tracks the migration from manually-deployed infrastructure components to Kubespray-managed add-ons, reducing configuration drift and maintenance burden.

## Changes Made (2026-01-01)

### 1. MetalLB Load Balancer
**File:** `inventory/wind/group_vars/k8s_cluster/addons.yml`

**Change:**
```yaml
metallb_enabled: true  # Was: false
metallb_config:
  address_pools:
    primary:
      ip_range:
        - 10.10.201.70-10.10.201.90  # Matches existing manual deployment
      auto_assign: true
  layer2:
    - primary
```

**Impact:**
- Kubespray will manage MetalLB via Helm
- IP pool matches existing manual deployment (10.10.201.70-90)
- **Migration Required:** Remove manual deployment from `platform/kubernetes/metallb/`

---

### 2. Multus CNI (Multi-Network Support)
**File:** `inventory/wind/group_vars/k8s_cluster/k8s-cluster.yml`

**Change:**
```yaml
kube_network_plugin_multus: true  # Was: false
```

**File:** `inventory/wind/group_vars/k8s_cluster/k8s-net-cilium.yml`

**Change:**
```yaml
cilium_cni_exclusive: false  # Was: true (commented)
```

**Impact:**
- Kubespray will install Multus CNI alongside Cilium
- Allows multi-VLAN access for Home Assistant and future workloads
- **No Migration Required:** Keep NetworkAttachmentDefinitions in `platform/kubernetes/multus/`
- NADs are overlays on top of Multus base installation

---

### 3. Node Feature Discovery (NFD)
**File:** `inventory/wind/group_vars/k8s_cluster/addons.yml`

**Change:**
```yaml
node_feature_discovery_enabled: true  # Was: false
```

**Impact:**
- Kubespray will manage NFD for GPU node labeling
- Prevents redundancy with GPU Operator's internal NFD
- Provides centralized feature detection for NVIDIA GPUs

---

### 4. Cert-Manager
**File:** `inventory/wind/group_vars/k8s_cluster/addons.yml`

**Change:**
```yaml
cert_manager_enabled: true  # Was: false
```

**Impact:**
- Explicit certificate management for the cluster
- **Future Migration:** Consider moving Traefik to use cert-manager ClusterIssuers instead of embedded ACME
- Provides better separation of concerns for certificate lifecycle

---

## Components Remaining External

These components are **NOT managed by Kubespray** and should remain in `platform/kubernetes/`:

### Traefik Ingress Controller
- **Location:** `platform/kubernetes/traefik/`
- **Reason:** Kubespray only supports Nginx ingress; Traefik requires Helm-based deployment
- **Status:** Keep as-is
- **Note:** Currently using embedded ACME; consider migrating to cert-manager in future

### Monitoring Stack (kube-prometheus-stack)
- **Location:** `platform/kubernetes/monitoring/`
- **Reason:** Not a Kubespray addon
- **Status:** Keep as-is
- **Components:** Prometheus, Alertmanager, Grafana

### GPU Operator
- **Location:** `platform/kubernetes/gpu-operator/`
- **Reason:** Not a Kubespray addon
- **Status:** Keep as-is
- **Note:** NFD now managed by Kubespray (prevent redundancy)

### Ceph CSI
- **Location:** `platform/kubernetes/storage/ceph-csi/`
- **Reason:** External Ceph cluster (sequoia.wind.etherport.net)
- **Status:** Keep as-is
- **Config:** Managed via Ansible in `inventory/wind/group_vars/all/ceph.yml`

### Application Workloads
- Kopia Backup (`platform/kubernetes/apps/kopia/`)
- Plex Media Server (`platform/kubernetes/plex/`)
- Home Assistant (`platform/kubernetes/home-automation/`)
- AWS S3 Backups (`platform/kubernetes/backups/aws-s3/`)

---

## Deployment Steps

### Prerequisites
1. Commit all Kubespray config changes to git
2. Review changes with `git diff`
3. Backup existing cluster state
4. Ensure cluster is healthy before starting

### Step 1: Re-run Kubespray (Enable Add-ons)

```bash
cd /Users/grahamsmith/Projects/homelab-infra/infra/ansible

# Run Kubespray to apply changes
ansible-playbook -i inventory/wind/hosts.yml \
  kubespray/cluster.yml \
  --tags network,apps

# Or for full cluster update:
ansible-playbook -i inventory/wind/hosts.yml kubespray/cluster.yml
```

This will:
- Install Multus CNI
- Deploy MetalLB via Helm
- Deploy Cert-Manager via Helm
- Deploy Node Feature Discovery via Helm

### Step 2: Verify Add-on Deployments

```bash
# Check Multus
kubectl get pods -n kube-system | grep multus

# Check MetalLB
kubectl get pods -n metallb-system
kubectl get ipaddresspools -n metallb-system
kubectl get l2advertisements -n metallb-system

# Check Cert-Manager
kubectl get pods -n cert-manager

# Check NFD
kubectl get pods -n node-feature-discovery
kubectl get nodes --show-labels | grep feature.node.kubernetes.io
```

### Step 3: Migrate MetalLB (Remove Manual Deployment)

**Before removing manual deployment, verify Kubespray MetalLB works:**

```bash
# Check that Traefik LoadBalancer IP is assigned
kubectl get svc -n traefik traefik -o wide

# Should show EXTERNAL-IP: 10.10.201.70
```

**Once verified, remove manual deployment:**

```bash
cd /Users/grahamsmith/Projects/homelab-infra

# Remove manual MetalLB manifests
git rm platform/kubernetes/metallb/metallb-wind.yaml

# Commit
git add -A
git commit -m "Remove manual MetalLB deployment (now managed by Kubespray)"
```

### Step 4: Apply Multus NetworkAttachmentDefinitions

```bash
# Apply multus-system namespace
kubectl apply -f platform/kubernetes/multus/base/namespace.yaml

# Apply NADs
kubectl apply -f platform/kubernetes/multus/network-attachment-definitions/

# Verify
kubectl get network-attachment-definitions -n multus-system
```

Expected output:
```
NAME               AGE
vlan202-client     1m
vlan204-iot        1m
vlan205-security   1m
```

### Step 5: Configure VLAN Interfaces on Nodes

**Prerequisites:**
- Terraform changes applied (additional NICs added to VMs)
- VMs rebooted to recognize new network adapters

```bash
# On each node (k8s-w1, k8s-w2, k8s-w3, k8s-gpu1)
# Follow instructions in: /Users/grahamsmith/Projects/homelab-infra/docs/kubernetes/node-vlan-setup.md

# Quick reference:
ssh k8s-w1
sudo bash -c 'cat > /etc/systemd/network/20-eth1.network <<EOF
[Match]
Name=eth1

[Network]
Address=10.10.202.51/24
Gateway=10.10.202.1
EOF'

# Repeat for eth2 (VLAN 204), eth3 (VLAN 205) on all nodes
# Then restart networking:
sudo systemctl restart systemd-networkd
```

### Step 6: Deploy Home Assistant

```bash
kubectl apply -f platform/kubernetes/home-automation/
```

---

## Rollback Plan

If issues occur, rollback steps:

### Rollback MetalLB
```bash
# Re-apply manual deployment
kubectl apply -f platform/kubernetes/metallb/metallb-wind.yaml

# Disable in Kubespray
# Set metallb_enabled: false in addons.yml
# Re-run ansible-playbook
```

### Rollback Multus
```bash
# Disable in Kubespray
# Set kube_network_plugin_multus: false
# Re-run ansible-playbook

# Manual cleanup if needed:
kubectl delete -n kube-system ds kube-multus-ds
```

---

## Verification Checklist

After migration, verify:

- [ ] All pods in kube-system are running
- [ ] MetalLB assigns IPs to LoadBalancer services
- [ ] Traefik ingress works (test: https://grafana.wind.etherport.net)
- [ ] Multus CNI pods running
- [ ] NADs exist in multus-system namespace
- [ ] NFD labels GPU nodes correctly
- [ ] Cert-Manager pods running
- [ ] No duplicate NFD installations
- [ ] Home Assistant has multi-VLAN access

---

## Configuration Drift Prevention

Going forward:

1. **Always check Kubespray first** before deploying infrastructure components
2. **Use Kubespray addons** when available
3. **Document external components** in `platform/kubernetes/EXTERNAL_COMPONENTS.md`
4. **Review annually** to see if new Kubespray versions support our external components

---

## References

- Kubespray Multus docs: `infra/ansible/kubespray/docs/CNI/multus.md`
- Kubespray addons: `inventory/wind/group_vars/k8s_cluster/addons.yml`
- Node VLAN setup: `docs/kubernetes/node-vlan-setup.md`
- Home Assistant deployment: `platform/kubernetes/home-automation/README.md`
