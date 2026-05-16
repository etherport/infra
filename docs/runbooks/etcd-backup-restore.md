# Etcd Backup and Restore

Procedures for backing up and restoring the Kubernetes etcd datastore.

## Overview

Etcd stores all Kubernetes cluster state including:
- Pod and deployment definitions
- ConfigMaps and Secrets
- Service accounts and RBAC
- Custom resources (CRDs)

Loss of etcd = loss of cluster state. Regular backups are critical.

## Backup Procedures

### Automated Backups (Recommended)

Kubespray can configure automated etcd snapshots. Add to `group_vars/all/etcd.yml`:

```yaml
etcd_snapshot_enabled: true
etcd_snapshot_schedule: "0 */6 * * *"  # Every 6 hours
etcd_snapshot_retention: 5              # Keep last 5 snapshots
etcd_snapshot_path: /var/lib/etcd/snapshots
```

### Manual Backup

SSH to any control plane node and run:

```bash
# On k8s-cp1 (or any control plane node)
sudo ETCDCTL_API=3 etcdctl snapshot save /tmp/etcd-backup-$(date +%Y%m%d-%H%M%S).db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key

# Verify snapshot
sudo ETCDCTL_API=3 etcdctl snapshot status /tmp/etcd-backup-*.db --write-out=table
```

### Pre-Migration Backup

Before major changes (like HA migration):

```bash
# Create timestamped backup
BACKUP_FILE="etcd-pre-migration-$(date +%Y%m%d-%H%M%S).db"
sudo ETCDCTL_API=3 etcdctl snapshot save /tmp/$BACKUP_FILE \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key

# Copy to local machine
scp ubuntu@k8s-cp1:/tmp/$BACKUP_FILE ~/backups/
```

## Restore Procedures

### Full Cluster Restore (Single CP)

If etcd is corrupted on a single control plane cluster:

```bash
# 1. Stop kubelet and etcd
sudo systemctl stop kubelet
sudo systemctl stop etcd

# 2. Remove old etcd data
sudo rm -rf /var/lib/etcd/*

# 3. Restore snapshot
sudo ETCDCTL_API=3 etcdctl snapshot restore /tmp/etcd-backup.db \
  --data-dir=/var/lib/etcd \
  --name=k8s-cp1 \
  --initial-cluster=k8s-cp1=https://10.10.201.50:2380 \
  --initial-advertise-peer-urls=https://10.10.201.50:2380

# 4. Fix permissions
sudo chown -R etcd:etcd /var/lib/etcd

# 5. Start services
sudo systemctl start etcd
sudo systemctl start kubelet

# 6. Verify cluster
kubectl get nodes
kubectl get pods -A
```

### HA Cluster Restore

For 3-node HA cluster, restore on each node with unique names:

```bash
# On k8s-cp1
sudo ETCDCTL_API=3 etcdctl snapshot restore /tmp/etcd-backup.db \
  --data-dir=/var/lib/etcd \
  --name=k8s-cp1 \
  --initial-cluster=k8s-cp1=https://10.10.201.50:2380,k8s-cp2=https://10.10.201.51:2380,k8s-cp3=https://10.10.201.52:2380 \
  --initial-advertise-peer-urls=https://10.10.201.50:2380

# On k8s-cp2
sudo ETCDCTL_API=3 etcdctl snapshot restore /tmp/etcd-backup.db \
  --data-dir=/var/lib/etcd \
  --name=k8s-cp2 \
  --initial-cluster=k8s-cp1=https://10.10.201.50:2380,k8s-cp2=https://10.10.201.51:2380,k8s-cp3=https://10.10.201.52:2380 \
  --initial-advertise-peer-urls=https://10.10.201.51:2380

# On k8s-cp3
sudo ETCDCTL_API=3 etcdctl snapshot restore /tmp/etcd-backup.db \
  --data-dir=/var/lib/etcd \
  --name=k8s-cp3 \
  --initial-cluster=k8s-cp1=https://10.10.201.50:2380,k8s-cp2=https://10.10.201.51:2380,k8s-cp3=https://10.10.201.52:2380 \
  --initial-advertise-peer-urls=https://10.10.201.52:2380
```

## Backup Storage

### Current Backup Locations

| Type | Location | Retention |
|------|----------|-----------|
| Velero | S3 (archive.wind.etherport.net) | 30 days |
| Etcd snapshots | /var/lib/etcd/snapshots | 5 snapshots |

### Recommended Off-Site Backup

For critical operations, copy etcd snapshots to S3:

```bash
# Copy to S3
aws s3 cp /tmp/etcd-backup-*.db s3://archive.wind.etherport.net/etcd-backups/
```

## Testing Backups

### Monthly Backup Test

1. Create fresh etcd snapshot
2. Spin up test VM (not production)
3. Restore snapshot to test VM
4. Verify data integrity

### Checklist

- [ ] Snapshot creates successfully
- [ ] Snapshot file is non-empty
- [ ] `etcdctl snapshot status` shows valid data
- [ ] Restore completes without errors
- [ ] Kubernetes API responds after restore
- [ ] Workloads are present in restored cluster

## Troubleshooting

### Snapshot Fails

```bash
# Check etcd health
sudo ETCDCTL_API=3 etcdctl endpoint health \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key
```

### Restore Fails

1. Check disk space: `df -h /var/lib/etcd`
2. Check permissions: `ls -la /var/lib/etcd`
3. Check etcd logs: `journalctl -u etcd -f`

## Related Documentation

- [Disaster Recovery](disaster-recovery.md)
- [Kubernetes HA Migration (archived — completed 2026-05-12)](../planning/archive/k8s-ha-migration.md)
- [Kubespray documentation](https://kubespray.io/)
