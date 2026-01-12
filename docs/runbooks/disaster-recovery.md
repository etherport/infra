# Disaster Recovery Runbook

Procedures for recovering from various failure scenarios in the homelab infrastructure.

## Recovery Priority

| Priority | Component | RTO | RPO |
|----------|-----------|-----|-----|
| P0 | DNS (Technitium cluster) | 5 min | 0 (real-time sync) |
| P0 | VPN (site-to-site) | 15 min | N/A |
| P1 | Kubernetes control plane | 30 min | Daily backup |
| P1 | Critical apps (Home Assistant) | 1 hour | Daily backup |
| P2 | Monitoring (Prometheus/Grafana) | 4 hours | Daily backup |
| P3 | Media services (Plex) | 24 hours | Daily backup |

---

## 1. Kubernetes Cluster Recovery

### 1.1 Single Worker Node Failure

**Symptoms:** Node shows NotReady, pods rescheduled to other nodes.

**Automatic Recovery:**
- Kubernetes automatically reschedules pods to healthy nodes
- No manual intervention needed if other workers have capacity

**Manual Intervention (if node won't recover):**

```bash
# Check node status
kubectl get nodes
kubectl describe node <failed-node>

# If node is permanently failed, remove it
kubectl drain <failed-node> --ignore-daemonsets --delete-emptydir-data --force
kubectl delete node <failed-node>

# Recreate node via Terraform
cd ~/Projects/homelab-infra/infra/terraform/proxmox/k8s-cluster
terraform apply -target=proxmox_virtual_environment_vm.k8s_workers["<node-name>"]

# Re-add to cluster via Kubespray
cd ~/Projects/homelab-infra/infra/kubespray
./kubespray.sh scale.yml --limit=<node-name>
```

### 1.2 Control Plane Failure

**Symptoms:** kubectl commands fail, API unreachable.

**Recovery Steps:**

```bash
# 1. Access control plane node directly
ssh graham@10.10.201.50

# 2. Check kubelet and container runtime
sudo systemctl status kubelet
sudo systemctl status containerd

# 3. Check etcd health
sudo crictl ps | grep etcd
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health

# 4. Check control plane pods
sudo crictl ps | grep -E 'kube-apiserver|kube-controller|kube-scheduler'

# 5. Restart kubelet if needed
sudo systemctl restart kubelet

# 6. Check logs
sudo journalctl -u kubelet -f
```

**Full Control Plane Rebuild (worst case):**

```bash
# Restore from Velero backup after rebuilding cluster
velero restore create cp-restore --from-backup kube-system-daily-<date>
```

### 1.3 Complete Cluster Loss

**Prerequisites:**
- Proxmox host operational
- Velero backups available in S3
- Access to kubespray inventory

**Recovery Procedure:**

```bash
# 1. Recreate VMs via Terraform
cd ~/Projects/homelab-infra/infra/terraform/proxmox/k8s-cluster
terraform apply

# 2. Wait for VMs to boot (5 minutes)
sleep 300

# 3. Deploy Kubernetes via Kubespray
cd ~/Projects/homelab-infra/infra/kubespray
./kubespray.sh cluster.yml

# 4. Install Velero
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
helm install velero vmware-tanzu/velero \
  --namespace velero --create-namespace \
  --set credentials.useSecret=true \
  --set configuration.provider=aws \
  --set configuration.backupStorageLocation.bucket=velero.wind.etherport.net \
  --set configuration.backupStorageLocation.config.region=us-west-2

# 5. Wait for Velero to sync with S3
kubectl wait --for=condition=Available -n velero deployment/velero --timeout=300s
velero backup-location get  # Should show "Available"

# 6. List available backups
velero backup get

# 7. Restore in order of priority
velero restore create restore-infra --from-backup infrastructure-daily-<latest>
velero restore create restore-critical --from-backup critical-apps-daily-<latest>
velero restore create restore-monitoring --from-backup monitoring-daily-<latest>

# 8. Deploy Flux to resume GitOps
flux bootstrap github \
  --owner=sparked-diamond \
  --repository=infra \
  --branch=main \
  --path=clusters/wind

# 9. Verify applications
kubectl get pods -A
flux get all -A
```

---

## 2. Storage Recovery

### 2.1 Ceph OSD Failure

**Symptoms:** Ceph health warning, degraded PGs.

```bash
# Check Ceph status
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd tree

# If OSD is down, check the node
kubectl get pods -n rook-ceph -o wide | grep osd

# Restart OSD pod
kubectl delete pod -n rook-ceph <osd-pod>
```

### 2.2 PVC Data Recovery

```bash
# List PVC backups from Velero
velero backup describe <backup-name> --details | grep -A 20 "PodVolumeBackups"

# Restore specific PVC
velero restore create pvc-restore \
  --from-backup <backup-name> \
  --include-namespaces <namespace> \
  --include-resources persistentvolumeclaims,persistentvolumes
```

---

## 3. DNS Recovery

### 3.1 Technitium Cluster Degraded

**Cluster nodes:** dns1, dns2 (K8s), dns-fallback (10.10.201.6), dns-aws (10.10.100.5)

```bash
# Check cluster status
curl -s "http://10.10.201.5:5380/api/admin/cluster/status?token=<token>"

# If K8s DNS pods are down, clients failover to dns-fallback
# UDM Pro DNS config: Primary=10.10.201.5, Secondary=10.10.201.6

# Restart K8s Technitium pods
kubectl rollout restart statefulset/technitium -n dns

# Check standalone nodes
curl -s "http://10.10.201.6:5380/api/dashboard/stats?token=<token>"
curl -s "http://10.10.100.5:5380/api/dashboard/stats?token=<token>"
```

### 3.2 Complete DNS Failure

**Immediate workaround:**
```bash
# On affected systems, use public DNS temporarily
echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf
```

**Recovery:**
```bash
# SSH to dns-fallback (standalone, always available)
ssh graham@10.10.201.6

# Restart Technitium
sudo systemctl restart technitium

# Verify
curl -s "http://localhost:5380/api/dashboard/stats?token=<token>"
```

---

## 4. VPN Recovery

### 4.1 Site-to-Site VPN Down

**Symptoms:** Cannot reach AWS resources (10.10.100.x) from local network.

```bash
# Check local VPN gateway
ssh graham@10.10.201.15 "sudo wg show"

# Check AWS VPN gateway (if reachable via public IP)
ssh ubuntu@44.240.60.80 "sudo wg show"

# Restart local WireGuard
ssh graham@10.10.201.15 "sudo systemctl restart wg-quick@wg0"

# Restart AWS WireGuard
ssh ubuntu@44.240.60.80 "sudo systemctl restart wg-quick@wg0"

# Verify tunnel
ping 10.255.255.1  # AWS tunnel endpoint
```

### 4.2 VPN Gateway VM Failure

```bash
# Recreate vpn-local VM
cd ~/Projects/homelab-infra/infra/terraform/proxmox/standalone-vms
terraform apply -target=proxmox_virtual_environment_vm.standalone["vpn-local"]

# Reconfigure WireGuard
cd ~/Projects/homelab-infra/infra/ansible
ansible-playbook -i inventory/wind/ playbooks/wireguard.yml --limit vpn-local
```

---

## 5. Application Recovery from Backup

### 5.1 Velero Restore Commands

```bash
# List available backups
velero backup get

# Describe backup contents
velero backup describe <backup-name> --details

# Restore entire backup
velero restore create <restore-name> --from-backup <backup-name>

# Restore specific namespace
velero restore create <restore-name> \
  --from-backup <backup-name> \
  --include-namespaces home-automation

# Restore specific resources
velero restore create <restore-name> \
  --from-backup <backup-name> \
  --include-resources deployments,services,configmaps

# Check restore status
velero restore describe <restore-name>
velero restore logs <restore-name>
```

### 5.2 Application-Specific Recovery

**Home Assistant:**
```bash
# Restore from critical-apps-daily backup
velero restore create ha-restore \
  --from-backup critical-apps-daily-<date> \
  --include-namespaces home-automation

# Verify
kubectl get pods -n home-automation
kubectl logs -n home-automation deploy/home-assistant
```

**Prometheus/Grafana:**
```bash
velero restore create monitoring-restore \
  --from-backup monitoring-daily-<date> \
  --include-namespaces monitoring
```

---

## 6. Proxmox Host Recovery

### 6.1 Single Proxmox Node Failure

**With clustered Proxmox (HA):**
- VMs automatically migrate to surviving nodes
- No manual intervention needed

**Standalone Proxmox (current setup):**

```bash
# 1. Restore Proxmox from backup or reinstall

# 2. Restore VM configurations from Proxmox Backup Server

# 3. Recreate VMs via Terraform
cd ~/Projects/homelab-infra/infra/terraform/proxmox/k8s-cluster
terraform apply
```

---

## 7. Recovery Verification Checklist

After any recovery, verify:

- [ ] `kubectl get nodes` - All nodes Ready
- [ ] `kubectl get pods -A | grep -v Running` - No stuck pods
- [ ] `flux get all -A` - All kustomizations synced
- [ ] `dig @10.10.201.5 google.com` - DNS working
- [ ] `ping 10.255.255.1` - VPN tunnel up
- [ ] `curl https://grafana.wind.etherport.net` - Ingress working
- [ ] Check Prometheus alerts - No critical alerts firing

---

## 8. Backup Verification

Run monthly to ensure backups are recoverable:

```bash
# Create test namespace
kubectl create namespace dr-test

# Restore to test namespace
velero restore create dr-test-restore \
  --from-backup critical-apps-daily-<date> \
  --namespace-mappings home-automation:dr-test

# Verify pods start
kubectl get pods -n dr-test

# Cleanup
kubectl delete namespace dr-test
```

---

## Related Documentation

- [PLATFORM-MANAGEMENT.md](../PLATFORM-MANAGEMENT.md) - Overall platform operations
- [operations-guide.md](operations-guide.md) - Command quick reference
- [UPDATE-PROCEDURES.md](UPDATE-PROCEDURES.md) - Update procedures and schedules
