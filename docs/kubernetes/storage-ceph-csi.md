# Ceph CSI Storage

## Purpose
Provide persistent volumes via Ceph RBD (preferred) or CephFS.

## Where files live
platform/kubernetes/storage/ceph-csi/
- ceph-config-map.yaml
- csi-config-map.yaml
- csi-kms-config-map.yaml
(plus any CSI deployment YAMLs you add later)

## Verify
kubectl get pods -A | grep -i csi
kubectl get storageclass
kubectl get pvc -A
kubectl get pv
