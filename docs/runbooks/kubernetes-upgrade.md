# Kubernetes Upgrade Procedures

Step-by-step procedures for upgrading Kubernetes cluster components.

## Current Versions

| Component | Version | Upgrade Frequency |
|-----------|---------|-------------------|
| Kubernetes | v1.33.7 | Quarterly |
| containerd | 2.1.5 | With K8s upgrade |
| Ubuntu | 24.04.3 LTS | Security: auto, Major: yearly |

## Upgrade Types

| Type | Risk | Downtime | Method |
|------|------|----------|--------|
| Patch (1.33.x → 1.33.y) | Low | None | Rolling update |
| Minor (1.33 → 1.34) | Medium | Minimal | Rolling update |
| Major (1.x → 2.x) | High | Possible | Planned maintenance |

---

## Pre-Upgrade Checklist

Before any upgrade:

- [ ] Review [Kubernetes changelog](https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG) for breaking changes
- [ ] Verify all nodes are Ready: `kubectl get nodes`
- [ ] Check for pending pods: `kubectl get pods -A | grep -v Running`
- [ ] Verify Velero backups are current: `velero backup get`
- [ ] Create manual backup: `velero backup create pre-upgrade-$(date +%Y%m%d)`
- [ ] Check Flux reconciliation: `kubectl get gitrepository,kustomization,helmrelease -A`
- [ ] Review deprecated APIs: `kubectl api-resources --api-group=<deprecated-group>`
- [ ] Notify users of maintenance window
- [ ] Ensure Proxmox has VM snapshots (optional safety net)
- [ ] Take an etcd snapshot from one CP member (the 3-CP HA cluster is
      backed up per the procedure in
      [etcd-backup-restore.md §HA Cluster Restore](etcd-backup-restore.md))

---

## 1. Patch Version Upgrade (e.g., 1.33.6 → 1.33.7)

Low risk, rolling update with zero downtime.

### 1.1 Update Kubespray Variables

```bash
cd ~/Projects/homelab-infra/infra/kubespray

# Check current version
grep kube_version inventory/wind/group_vars/k8s_cluster/k8s-cluster.yml

# Update to new patch version
vim inventory/wind/group_vars/k8s_cluster/k8s-cluster.yml
# Change: kube_version: v1.33.7
```

### 1.2 Run Upgrade Playbook

```bash
# Activate virtual environment
source venv/bin/activate

# Run upgrade (control plane first, then workers)
./kubespray.sh upgrade-cluster.yml \
  --become --become-user=root

# Or upgrade one node at a time (safer)
./kubespray.sh upgrade-cluster.yml \
  --become --become-user=root \
  --limit k8s-cp1

./kubespray.sh upgrade-cluster.yml \
  --become --become-user=root \
  --limit k8s-w1

# Continue for each worker...
```

### 1.3 Verify Upgrade

```bash
# Check all nodes are at new version
kubectl get nodes -o wide

# Verify system pods
kubectl get pods -n kube-system

# Check cluster health
kubectl cluster-info
kubectl get componentstatuses
```

---

## 2. Minor Version Upgrade (e.g., 1.33 → 1.34)

Medium risk, requires API deprecation review.

### 2.1 Pre-Upgrade Steps

```bash
# Check for deprecated APIs in use
kubectl get --raw /metrics | grep apiserver_requested_deprecated_apis

# Audit specific deprecated APIs
kubectl api-resources --api-group=extensions

# Check if any manifests use deprecated APIs
grep -r "apiVersion: extensions/v1beta1" platform/kubernetes/

# Review removed features in release notes
# https://kubernetes.io/docs/setup/release/notes/
```

### 2.2 Update Kubespray

```bash
cd ~/Projects/homelab-infra/infra/kubespray

# Pull latest kubespray (if needed)
git fetch upstream
git checkout release-2.x  # Match your kubespray version

# Update version in inventory
vim inventory/wind/group_vars/k8s_cluster/k8s-cluster.yml
# Change: kube_version: v1.34.0
```

### 2.3 Upgrade Control Plane First

```bash
# Upgrade control plane only
./kubespray.sh upgrade-cluster.yml \
  --become --become-user=root \
  --limit kube_control_plane

# Verify control plane
kubectl get nodes
kubectl get pods -n kube-system | grep -E 'apiserver|controller|scheduler'
```

### 2.4 Upgrade Workers (Rolling)

```bash
# Upgrade workers one at a time
for node in k8s-w1 k8s-w2 k8s-w3 k8s-w4 k8s-gpu1; do
  echo "=== Upgrading $node ==="

  # Cordon node
  kubectl cordon $node

  # Drain workloads
  kubectl drain $node --ignore-daemonsets --delete-emptydir-data

  # Run upgrade
  ./kubespray.sh upgrade-cluster.yml \
    --become --become-user=root \
    --limit $node

  # Uncordon node
  kubectl uncordon $node

  # Wait for pods to reschedule
  sleep 60
  kubectl get pods -A | grep -v Running | grep -v Completed

  echo "=== $node complete ==="
done
```

### 2.5 Post-Upgrade Verification

```bash
# All nodes at new version
kubectl get nodes -o wide

# No pending/failing pods
kubectl get pods -A | grep -v Running | grep -v Completed

# Flux reconciliation healthy
kubectl get gitrepository,kustomization,helmrelease -A

# Test application access
curl -k https://grafana.wind.etherport.net
dig @10.10.201.5 google.com
```

---

## 3. Component Upgrades

### 3.1 containerd Upgrade

Usually done as part of K8s upgrade via kubespray.

```bash
# Check current version
kubectl get nodes -o wide | awk '{print $NF}'

# containerd is upgraded via kubespray
# Set in: inventory/wind/group_vars/all/containerd.yml
```

### 3.2 Helm Chart Upgrades

```bash
# List installed releases
helm list -A

# Check for updates
helm repo update
helm search repo <chart-name> --versions

# Upgrade specific release
helm upgrade <release> <chart> -n <namespace> \
  -f platform/kubernetes/<app>/values.yaml \
  --version <new-version>

# Example: Upgrade kube-prometheus-stack
helm upgrade monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f platform/kubernetes/monitoring/values.yaml
```

### 3.3 Flux Upgrade

```bash
# Check current controller versions (no flux CLI on the hosts)
kubectl get pods -n flux-system -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'

# Upgrade Flux controllers by applying the versioned install manifest
# (the components used in clusters/wind/flux-system/gotk-components.yaml)
kubectl apply -f https://github.com/fluxcd/flux2/releases/download/v2.x.x/install.yaml

# Verify the controllers came back Ready
kubectl get pods -n flux-system
```

---

## 4. Rollback Procedures

### 4.1 Immediate Rollback (during upgrade)

```bash
# If node fails during upgrade, it will remain at old version
# Fix issues and re-run upgrade playbook

# If control plane fails:
# 1. SSH to control plane node (cp1/cp2/cp3 — .50/.51/.52)
ssh -i /tmp/auto-key ubuntu@10.10.201.50

# 2. Check kubelet logs
sudo journalctl -u kubelet -f

# 3. Check container runtime
sudo crictl ps

# 4. Restart kubelet
sudo systemctl restart kubelet
```

### 4.2 Version Rollback

```bash
# Kubespray doesn't officially support downgrades
# Options:

# Option 1: Restore from VM snapshots (if available)
# Via Proxmox UI

# Option 2: Restore from Velero backup
# Requires cluster rebuild at old version

# Option 3: Hold current version, fix issues at new version
```

---

## 5. Emergency Procedures

### 5.1 Stuck Upgrade

```bash
# If ansible fails mid-upgrade:

# Check which nodes completed
kubectl get nodes -o wide

# Resume from failed node
./kubespray.sh upgrade-cluster.yml \
  --become --become-user=root \
  --limit <failed-node> \
  --start-at-task="<task-name>"
```

### 5.2 API Server Unavailable

```bash
# SSH to control plane (any of cp1/cp2/cp3)
ssh -i /tmp/auto-key ubuntu@10.10.201.50

# Check API server container
sudo crictl ps | grep kube-apiserver

# Check logs
sudo crictl logs <container-id>

# Restart static pod
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
sleep 10
sudo mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
```

### 5.3 etcd Issues

```bash
# SSH to control plane (any of cp1/cp2/cp3 — etcd is HA, 3 members)
ssh -i /tmp/auto-key ubuntu@10.10.201.50

# Check etcd health
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health

# Check etcd logs
sudo crictl logs $(sudo crictl ps | grep etcd | awk '{print $1}')
```

---

## 6. Upgrade Schedule

| Quarter | Activity |
|---------|----------|
| Q1 | Minor version upgrade (if available) |
| Q2 | Patch updates only |
| Q3 | Minor version upgrade (if available) |
| Q4 | Security patches, prepare for next year |

---

## 7. Testing Upgrades

### 7.1 Test Cluster (if available)

Before upgrading production:

1. Spin up test cluster with same version
2. Run upgrade procedure
3. Test critical applications
4. Document any issues

### 7.2 Production Testing Post-Upgrade

```bash
# Run integration tests
kubectl run test-pod --image=busybox --rm -it --restart=Never -- wget -qO- http://service

# Check storage
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
  storageClassName: ceph-rbd
EOF

kubectl get pvc test-pvc
kubectl delete pvc test-pvc

# Check ingress
curl -k https://grafana.wind.etherport.net
```

---

## Related Documentation

- [UPDATE-PROCEDURES.md](UPDATE-PROCEDURES.md) - All update procedures and schedules
- [disaster-recovery.md](disaster-recovery.md) - Recovery procedures
- [PLATFORM-MANAGEMENT.md](PLATFORM-MANAGEMENT.md) - Overall platform operations
- [operations-guide.md](operations-guide.md) - Command quick reference
