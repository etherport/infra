# k8s-w3 Deployment Plan with IP Reorganization (SUPERSEDED — ARCHIVED)

> **Status: superseded.** This single-node addition plan was overtaken
> by the full HA migration on 2026-05-12, which rebuilt the cluster as
> 3 CP (.50/.51/.52) + 4 workers (.53-.56) + 1 GPU (.60). Kept for
> historical context only. For current state see
> `docs/architecture/overview.md`.

**Date**: 2026-01-02
**Objective**: Add third worker node (k8s-w3) and reorganize IPs for clean addressing
**Duration**: ~4 hours
**Downtime**: Plex and GPU workloads only (~30 minutes)

## IP Address Changes

| Node | Old IP | New IP | Change |
|------|--------|--------|--------|
| k8s-cp1 | 10.10.201.50 | 10.10.201.50 | No change |
| k8s-w1 | 10.10.201.51 | 10.10.201.51 | No change |
| k8s-w2 | 10.10.201.52 | 10.10.201.52 | No change |
| k8s-w3 | N/A | **10.10.201.53** | **NEW** |
| k8s-gpu1 | 10.10.201.53 | **10.10.201.60** | **CHANGED** |

**Result**: Workers occupy .50-.53, leaving .54-.59 for future expansion, GPU nodes at .60+

---

## Prerequisites

- [x] Terraform configured and tested
- [x] Ansible/Kubespray virtualenv activated
- [x] Backup of GPU node workloads (Plex data on Ceph - safe)
- [x] GPU node taint removed (already done)
- [x] Proxmox credentials ready
- [x] Time window: ~4 hours

---

## Phase 1: Pre-Migration (30 minutes)

### 1.1 Drain k8s-gpu1

```bash
# Cordon to prevent new pods
kubectl cordon k8s-gpu1

# Drain the node (may take 10-15 minutes)
kubectl drain k8s-gpu1 --ignore-daemonsets --delete-emptydir-data --force

# Verify only DaemonSets remain
kubectl get pods --all-namespaces -o wide --field-selector spec.nodeName=k8s-gpu1
```

### 1.2 Remove k8s-gpu1 from Cluster

```bash
cd ~/Projects/homelab-infra/infra/kubespray

# Remove the node
./kubespray.sh remove-node.yml -e node=k8s-gpu1

# Verify removal
kubectl get nodes
# k8s-gpu1 should NOT appear
```

---

## Phase 2: Infrastructure Changes (30 minutes)

### 2.1 Apply Terraform Changes

```bash
cd /Users/grahamsmith/Projects/homelab-infra/infra/terraform/proxmox/k8s-vms

# Review changes
terraform plan
# Expected: Create k8s-w3, update k8s-gpu1 IP

# Apply
terraform apply
```

**Note**: Terraform will attempt to change the cloud-init IP for k8s-gpu1. This may require stopping/starting the VM.

### 2.2 Manually Update k8s-gpu1 IP (if needed)

If Terraform cannot change the IP automatically:

```bash
# SSH to GPU node using old IP
ssh graham@10.10.201.53

# Check current netplan config
cat /etc/netplan/50-cloud-init.yaml

# Update IP if needed
sudo nano /etc/netplan/50-cloud-init.yaml
# Change address to: 10.10.201.60/24

# Apply
sudo netplan apply

# Verify
ip addr show eth0 | grep inet
# Should show 10.10.201.60/24

# Exit SSH
exit
```

### 2.3 Verify New Nodes are Accessible

```bash
# Test k8s-w3 (new node)
ssh graham@10.10.201.53
exit

# Test k8s-gpu1 (updated IP)
ssh graham@10.10.201.60
exit
```

---

## Phase 3: Configure Multi-VLAN Interfaces (20 minutes)

### 3.1 Configure k8s-w3 VLANs

```bash
ssh graham@10.10.201.53

# Create systemd-networkd config for VLAN 202 (Client)
sudo tee /etc/systemd/network/10-eth1.network <<EOF
[Match]
Name=eth1

[Network]
Address=10.10.202.53/24
ConfigureWithoutCarrier=yes

[Link]
RequiredForOnline=no
EOF

# VLAN 204 (IoT)
sudo tee /etc/systemd/network/10-eth2.network <<EOF
[Match]
Name=eth2

[Network]
Address=10.10.204.53/24
ConfigureWithoutCarrier=yes

[Link]
RequiredForOnline=no
EOF

# VLAN 205 (Security)
sudo tee /etc/systemd/network/10-eth3.network <<EOF
[Match]
Name=eth3

[Network]
Address=10.10.205.53/24
ConfigureWithoutCarrier=yes

[Link]
RequiredForOnline=no
EOF

# Enable and restart
sudo systemctl enable systemd-networkd
sudo systemctl restart systemd-networkd

# Verify
ip -br addr show eth1 eth2 eth3

exit
```

### 3.2 Update k8s-gpu1 VLAN IPs

```bash
ssh graham@10.10.201.60

# Update VLAN 202 (Client)
sudo tee /etc/systemd/network/10-eth1.network <<EOF
[Match]
Name=eth1

[Network]
Address=10.10.202.60/24
ConfigureWithoutCarrier=yes

[Link]
RequiredForOnline=no
EOF

# VLAN 204 (IoT)
sudo tee /etc/systemd/network/10-eth2.network <<EOF
[Match]
Name=eth2

[Network]
Address=10.10.204.60/24
ConfigureWithoutCarrier=yes

[Link]
RequiredForOnline=no
EOF

# VLAN 205 (Security)
sudo tee /etc/systemd/network/10-eth3.network <<EOF
[Match]
Name=eth3

[Network]
Address=10.10.205.60/24
ConfigureWithoutCarrier=yes

[Link]
RequiredForOnline=no
EOF

# Restart
sudo systemctl restart systemd-networkd

# Verify
ip -br addr show eth1 eth2 eth3

exit
```

---

## Phase 4: Rejoin Nodes to Cluster (60 minutes)

### 4.1 Refresh Ansible Facts

```bash
cd ~/Projects/homelab-infra/infra/kubespray

# Refresh facts for all nodes
./kubespray.sh kubespray/playbooks/facts.yml
```

### 4.2 Add k8s-w3 to Cluster

```bash
# Run scale playbook for new node
./kubespray.sh scale.yml --limit=k8s-w3
```

**Expected time**: 30-40 minutes

### 4.3 Add k8s-gpu1 with New IP

```bash
# Run scale playbook for GPU node
./kubespray.sh scale.yml --limit=k8s-gpu1
```

**Expected time**: 30-40 minutes

---

## Phase 5: Verification (30 minutes)

### 5.1 Verify All Nodes are Ready

```bash
kubectl get nodes -o wide
```

Expected output:
```
NAME       STATUS   ROLES           AGE   VERSION   INTERNAL-IP
k8s-cp1    Ready    control-plane   XXd   v1.34.2   10.10.201.50
k8s-w1     Ready    <none>          XXd   v1.34.2   10.10.201.51
k8s-w2     Ready    <none>          XXd   v1.34.2   10.10.201.52
k8s-w3     Ready    <none>          XXm   v1.34.2   10.10.201.53  ← NEW
k8s-gpu1   Ready    <none>          XXm   v1.34.2   10.10.201.60  ← UPDATED
```

### 5.2 Verify DaemonSets

```bash
# Check Cilium agents
kubectl get pods -n kube-system -l k8s-app=cilium -o wide

# Check node-local-dns
kubectl get pods -n kube-system -l k8s-app=node-local-dns -o wide

# Check MetalLB speakers
kubectl get pods -n metallb-system -o wide

# Check CSI RBD plugin
kubectl get pods -n default -l app=csi-rbdplugin -o wide
```

All should show 5 pods (one per node).

### 5.3 Test Pod Scheduling on k8s-w3

```bash
# Create test pod
kubectl run test-w3 --image=nginx --overrides='{"spec":{"nodeName":"k8s-w3"}}'

# Verify it's running
kubectl get pod test-w3 -o wide

# Clean up
kubectl delete pod test-w3
```

### 5.4 Uncordon and Test GPU Node

```bash
# Uncordon k8s-gpu1
kubectl uncordon k8s-gpu1

# Verify GPU functionality
kubectl run gpu-test --image=nvidia/cuda:11.0-base --restart=Never \
  --overrides='{"spec":{"nodeName":"k8s-gpu1"}}' \
  -- nvidia-smi

# Check logs
kubectl logs gpu-test

# Clean up
kubectl delete pod gpu-test
```

### 5.5 Verify GPU Operator Pods

```bash
kubectl get pods -n gpu-operator-system -o wide
```

All GPU operator pods should be Running on k8s-gpu1.

### 5.6 Check Resource Distribution

```bash
# Show resource allocation across all nodes
kubectl describe nodes | grep -A 15 "Allocated resources:"
```

---

## Phase 6: Update Documentation (15 minutes)

### 6.1 Update DNS Zone File

Edit: `/Users/grahamsmith/Projects/homelab-infra/platform/kubernetes/technitium/wind.etherport.net.zone`

```diff
; ============================================================
; Kubernetes Cluster Nodes
; ============================================================
k8s-cp1         IN      A       10.10.201.50        ; Control Plane
k8s-w1          IN      A       10.10.201.51        ; Worker 1
k8s-w2          IN      A       10.10.201.52        ; Worker 2
+k8s-w3          IN      A       10.10.201.53        ; Worker 3
-k8s-gpu1        IN      A       10.10.201.53        ; GPU Worker
+k8s-gpu1        IN      A       10.10.201.60        ; GPU Worker
```

### 6.2 Update Node Documentation

Edit: `/Users/grahamsmith/Projects/homelab-infra/docs/kubernetes/node-vlan-setup.md`

Add k8s-w3 to the node table and update k8s-gpu1 IP.

### 6.3 Commit Changes

```bash
cd /Users/grahamsmith/Projects/homelab-infra

git add -A
git commit -m "Add k8s-w3 worker node and reorganize IPs

- Add k8s-w3 at 10.10.201.53 (4 CPU / 8GB RAM)
- Move k8s-gpu1 from .53 to .60 for clean IP organization
- Update Terraform, Ansible inventory, and documentation
- Workers now occupy .50-.53, .54-.59 reserved for future expansion
- GPU nodes at .60+

🤖 Generated with Claude Code

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"

git push
```

---

## Rollback Plan

If issues occur after removing k8s-gpu1 but before rejoining:

```bash
# Revert Terraform
cd ~/Projects/homelab-infra/infra/terraform/proxmox/k8s-vms
git checkout main.tf

# Revert inventory
cd ~/Projects/homelab-infra/infra/kubespray/inventory/wind
git checkout inventory.ini

# Apply original config
terraform apply

# Rejoin GPU node with original IP
cd ~/Projects/homelab-infra/infra/kubespray
./kubespray.sh scale.yml --limit=k8s-gpu1
```

---

## Success Criteria

- [  ] 5 nodes in Ready state
- [  ] All DaemonSets have 5 pods
- [  ] k8s-w3 accessible at 10.10.201.53
- [  ] k8s-gpu1 accessible at 10.10.201.60
- [  ] GPU operator functional on k8s-gpu1
- [  ] Test pods can schedule on all nodes
- [  ] Documentation updated
- [  ] Changes committed to git

---

## Timeline Summary

| Phase | Duration | Status |
|-------|----------|--------|
| 1. Pre-Migration (Drain & Remove) | 30 min | ⏸️ Pending |
| 2. Infrastructure Changes (Terraform) | 30 min | ⏸️ Pending |
| 3. VLAN Configuration | 20 min | ⏸️ Pending |
| 4. Rejoin Nodes (Kubespray) | 60 min | ⏸️ Pending |
| 5. Verification | 30 min | ⏸️ Pending |
| 6. Documentation | 15 min | ⏸️ Pending |
| **Total** | **~3 hours** | |

---

## Notes

- GPU node downtime: ~30-45 minutes (during removal, IP change, rejoin)
- Other nodes: No disruption
- S3 sync jobs currently running on k8s-w2 - unaffected
- After completion, workloads will automatically spread to new node
- GPU taint already removed, so all nodes can accept general workloads

---

## Next Steps After Completion

1. Monitor S3 sync jobs for completion
2. Consider adding pod anti-affinity to S3 sync CronJobs
3. Plan control plane HA for Q1 2026 (requires 2 more control plane nodes)
4. Review and implement update automation (Renovate)
