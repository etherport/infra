# Ceph CSI Storage

## Purpose
Provide persistent volumes via Ceph RBD (preferred) or CephFS.

## Where files live
platform/kubernetes/storage/ceph-csi/ (Flux-reconciled via `clusters/wind/kustomization.yaml`)
- ceph-config-map.yaml
- csi-config-map.yaml
- csi-kms-config-map.yaml
- csi-driver.yaml
- kustomization.yaml

The backing Ceph cluster is **external, on the PVE host** (mon `10.10.210.41`, pool
`k8s-ceph`, dedicated storage VLAN 210). NB the PVE host firewall must keep the
`pve-ceph` allow (storage VLAN → mon/OSD) — see CLAUDE.md §5.

## Verify
kubectl get pods -A | grep -i csi
kubectl get storageclass
kubectl get pvc -A
kubectl get pv
