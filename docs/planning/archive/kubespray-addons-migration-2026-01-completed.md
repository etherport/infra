# Kubespray Configuration Migration (HISTORICAL — completed 2026-01)

> **Status: completed.** All migrations listed below shipped in early
> 2026. The current cluster is the 3-CP-HA build from 2026-05-12 and
> all of the add-ons described here (MetalLB, Multus, NFD, cert-manager)
> are live and Flux- or kubespray-managed as documented. Keep this file
> as a record of how we got here; do not use as a live runbook. For
> current state see [`../kubespray/README.md`](../kubespray/README.md)
> and [`../../docs/runbooks/PLATFORM-MANAGEMENT.md`](../../docs/runbooks/PLATFORM-MANAGEMENT.md).

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
- Kopia Backup (`platform/kubernetes/kopia/`)
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

### Step 1: Run Pre-flight Playbook

**CRITICAL:** The pre-flight playbook MUST be run before Kubespray to set correct directory ownership for CNI components.

```bash
cd ~/Projects/homelab-infra/infra/kubespray

# Run pre-flight playbook
./kubespray.sh ../inventory/pre-flight.yml
```

This ensures:
- `/opt/cni/bin` is owned by `root:root` (required for Cilium init containers)
- Cilium runtime directories exist with correct permissions
- NFS client utilities are installed

### Step 2: Run Kubespray (Enable Add-ons)

```bash
cd ~/Projects/homelab-infra/infra/kubespray

# IMPORTANT: Use inventory.ini not hosts.yml
# IMPORTANT: Run full playbook without tags to ensure all setup tasks run

./kubespray.sh cluster.yml
```

**Why full playbook without tags:**
- Running with `--tags` skips important preinstall tasks
- Directory permissions may not be set correctly
- Download tasks may be skipped, causing failures
- The playbook is idempotent - it only changes what needs changing

This will:
- Run preinstall tasks (create directories, download binaries)
- Update Cilium configuration (cni-exclusive: false for Multus)
- Install Multus CNI
- Deploy MetalLB with IPAddressPool and L2Advertisement
- Deploy Cert-Manager
- Deploy Node Feature Discovery

### Step 3: Deploy Ceph CSI (External Storage)

**IMPORTANT:** Ceph CSI is not part of Kubespray and must be deployed separately to enable persistent storage.

```bash
cd ~/Projects/homelab-infra/infra/kubespray

# Deploy Ceph CSI RBD driver (uses wrapper script)
./kubespray.sh ../ansible/playbooks/ceph/ceph-k8s.upstream-reference.yml

# If using ansible-vault encrypted secrets:
# ./kubespray.sh ../ansible/playbooks/ceph/ceph-k8s.upstream-reference.yml --ask-vault-pass
```

**Verify Ceph CSI deployment:**
```bash
# Check CSI pods are running
kubectl get pods -n ceph-csi

# Check CSI driver is registered
kubectl get csidrivers | grep ceph

# Check storage class exists
kubectl get sc ceph-rbd

# Verify test PVC is created and bound
kubectl get pvc -n default rbd-test-pvc
```

### Step 4: Verify Add-on Deployments

```bash
# Check Cilium (should all be Running)
kubectl get pods -n kube-system -l k8s-app=cilium

# Check Multus
kubectl get pods -n kube-system | grep multus

# Check MetalLB (should all be 1/1 Running)
kubectl get pods -n metallb-system
kubectl get ipaddresspools -n metallb-system
kubectl get l2advertisements -n metallb-system

# Check Cert-Manager
kubectl get pods -n cert-manager

# Check NFD
kubectl get pods -n node-feature-discovery
kubectl get nodes --show-labels | grep feature.node.kubernetes.io

# CRITICAL: Verify Traefik has LoadBalancer IP
kubectl get svc -n traefik traefik
# Should show EXTERNAL-IP: 10.10.201.70 (not <pending>)
```

### Step 5: Migrate MetalLB (Remove Manual Deployment)

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

### Step 6: Apply Multus NetworkAttachmentDefinitions

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

### Step 7: Configure VLAN Interfaces on Nodes

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

### Step 8: Deploy Home Assistant

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

## Security Improvements (Production Readiness)

### 1. Encrypt Ceph Credentials with Ansible Vault

**Current State:** Ceph credentials are stored in plaintext in `infra/kubespray/inventory/wind/group_vars/all/ceph.yml`

**Recommended:** Encrypt with ansible-vault

```bash
cd ~/Projects/homelab-infra/infra/kubespray

# Encrypt the file (using venv ansible-vault)
source kubespray/venv/bin/activate
ansible-vault encrypt inventory/wind/group_vars/all/ceph.yml

# Future playbook runs will need vault password
./kubespray.sh cluster.yml --ask-vault-pass

# Or use a password file (keep this file secure, not in git!)
./kubespray.sh cluster.yml --vault-password-file ~/.ansible-vault-pass
```

**Alternative Options:**
- **External Secrets Operator**: Sync secrets from external vault (HashiCorp Vault, AWS Secrets Manager)
- **Sealed Secrets**: Encrypt secrets that can only be decrypted in-cluster

### 2. Review Other Sensitive Data

Check for other plaintext secrets:
```bash
# Search for potential secrets in inventory
grep -r "key\|password\|secret" inventory/wind/group_vars/ --include="*.yml"
```

Consider ansible-vault for any sensitive values.

---

## Configuration Drift Prevention

Going forward:

1. **Always check Kubespray first** before deploying infrastructure components
2. **Use Kubespray addons** when available
3. **Document external components** in `platform/kubernetes/EXTERNAL_COMPONENTS.md`
4. **Review annually** to see if new Kubespray versions support our external components
5. **Run deployment playbooks in order**: pre-flight → cluster.yml → ceph-k8s → verify

---

## References

- Kubespray Multus docs: `infra/kubespray/kubespray/docs/CNI/multus.md`
- Kubespray addons: `infra/kubespray/inventory/wind/group_vars/k8s_cluster/addons.yml`
- Node VLAN setup: `docs/kubernetes/node-vlan-setup.md`
- Home Assistant deployment: `platform/kubernetes/home-automation/README.md`
