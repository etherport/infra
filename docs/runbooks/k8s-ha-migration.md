# Kubernetes HA Migration Runbook

Migration from single control plane to 3-node HA cluster with expanded workers.

## Overview

| Before | After |
|--------|-------|
| 1 control plane (8GB) | 3 control planes (4GB each) |
| 4 workers (8GB each) | 4 workers (10GB each) |
| 1 GPU worker (24GB) | 1 GPU worker (20GB) |
| Total: 56GB | Total: 72GB |

## Prerequisites

- [ ] Packer template (VM 9000) built successfully
- [ ] Terraform configs updated
- [ ] Kubespray inventory updated
- [ ] Velero backup completed
- [ ] VPN failover verified (vpn-local accessible)

## Pre-Migration Checklist

```bash
# 1. Verify current cluster health
kubectl get nodes
kubectl get pods -A | grep -v Running

# 2. Create Velero backup
velero backup create pre-ha-migration --wait

# 3. Verify VPN failover
# From outside network, test vpn-local is reachable
ping 10.10.201.15

# 4. Verify DNS fallback
dig @10.10.201.6 google.com

# 5. Document current state
kubectl get nodes -o wide > /tmp/nodes-before.txt
kubectl get pods -A -o wide > /tmp/pods-before.txt
```

## Migration Strategy

**Approach: Fresh cluster build** (recommended for major architecture change)

Since we're going from 1 CP to 3 CP with new IPs, it's cleaner to:
1. Build new infrastructure
2. Bootstrap fresh cluster
3. Restore from Velero backup
4. Update DNS/services to point to new cluster

This avoids complex in-place etcd membership changes.

## Phase 1: Prepare Infrastructure

```bash
# 1. Verify Packer template exists
ssh graham@pve.wind.etherport.net "qm config 9000"

# 2. Destroy old K8s VMs (after backup!)
cd infra/terraform/proxmox/k8s-vms
terraform plan -destroy
# Review carefully!
terraform destroy

# 3. Apply new VM configuration
terraform plan
terraform apply
```

## Phase 2: Deploy New Cluster

```bash
# 1. Setup kubespray environment
cd infra/kubespray
./setup.sh

# 2. Verify connectivity to new VMs
ansible -i inventory/wind/ k8s_cluster -m ping

# 3. Deploy Kubernetes cluster
./kubespray.sh cluster.yml

# 4. Get kubeconfig
export KUBECONFIG=inventory/wind/artifacts/admin.conf
kubectl get nodes
```

## Phase 3: Install Flux and Restore

```bash
# 1. Bootstrap Flux
flux bootstrap github \
  --owner=sparked-diamond \
  --repository=infra \
  --branch=main \
  --path=clusters/wind \
  --personal

# 2. Wait for Flux to sync
flux get kustomizations --watch

# 3. Verify core services
kubectl get pods -n flux-system
kubectl get helmreleases -A

# 4. Restore Velero backup (if needed for PVCs)
velero restore create --from-backup pre-ha-migration
```

## Phase 4: Verify and Cutover

```bash
# 1. Verify all pods running
kubectl get pods -A | grep -v Running

# 2. Verify services accessible
curl -k https://grafana.wind.etherport.net
curl -k https://home-assistant.wind.etherport.net

# 3. Verify HA - test control plane failover
kubectl get nodes
# Stop one control plane VM in Proxmox
# Verify cluster still operational
kubectl get nodes
kubectl get pods -A
```

## Rollback Plan

If migration fails:

```bash
# 1. Keep Velero backup
velero backup describe pre-ha-migration

# 2. If needed, restore old Terraform state
cd infra/terraform/proxmox/k8s-vms
git checkout HEAD~1 -- main.tf
terraform apply

# 3. Restore from backup
velero restore create --from-backup pre-ha-migration
```

## Post-Migration

- [ ] Verify all services operational
- [ ] Test HA failover (stop one CP, verify cluster works)
- [ ] Update monitoring alerts for new node count
- [ ] Update documentation
- [ ] Delete old Velero backup after 7 days

## IP Address Reference

| Node | Old IP | New IP |
|------|--------|--------|
| k8s-cp1 | 10.10.201.50 | 10.10.201.50 |
| k8s-cp2 | - | 10.10.201.51 |
| k8s-cp3 | - | 10.10.201.52 |
| k8s-w1 | 10.10.201.51 | 10.10.201.53 |
| k8s-w2 | 10.10.201.52 | 10.10.201.54 |
| k8s-w3 | 10.10.201.53 | 10.10.201.55 |
| k8s-w4 | - | 10.10.201.56 |
| k8s-gpu1 | 10.10.201.60 | 10.10.201.60 |

## Estimated Timeline

| Phase | Duration |
|-------|----------|
| Pre-migration checks | 10 min |
| Destroy old VMs | 5 min |
| Create new VMs | 10 min |
| Kubespray deploy | 20-30 min |
| Flux bootstrap | 10 min |
| Verification | 15 min |
| **Total** | **~1-1.5 hours** |

## Expected Downtime

- **K8s services**: ~45-60 minutes (during cluster rebuild)
- **VPN**: Should failover to vpn-local automatically
- **DNS**: dns-fallback (10.10.201.6) provides continuity
