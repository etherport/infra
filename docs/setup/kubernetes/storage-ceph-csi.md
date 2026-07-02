# Ceph CSI Storage

> **M120 (2026-07-01):** the FULL ceph-csi stack (provisioner Deployment, node
> DaemonSet, SAs, RBAC) is now codified in `platform/kubernetes/storage/ceph-csi/`
> and runs in the **`ceph-csi` namespace** (it previously ran as an out-of-band
> apply in `default`). The SC-referenced `csi-rbd-secret` lives in `ceph-csi`
> (unchanged). ⚠️ History note: an out-of-band configmap copy in ceph-csi carried
> the pre-VLAN-migration monitor `10.10.201.41` — git's `10.10.210.41` config is
> authoritative; never hand-edit the live configmaps.

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
