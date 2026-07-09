# Disaster Recovery Runbook

Procedures for recovering from various failure scenarios in the homelab infrastructure.

## Recovery Priority

The table below is a **target** + **last-measured** view. RTO =
time from incident → service back. RPO = max acceptable data loss.
A `?` in the Measured column means we've never actually drilled
this — the number is aspirational. Run the drill in §11 below and
update.

| Priority | Component | Target RTO | Target RPO | Measured RTO | Measured RPO | Last drill |
|---|---|---|---|---|---|---|
| P0 | DNS (Technitium cluster) | 5 min | 0 (real-time sync) | ? | ? | never |
| P0 | VPN (site-to-site) | 15 min | N/A | ? | N/A | never |
| P1 | Kubernetes control plane | 30 min | 24 h (daily etcd snapshot) | ? | ? | never |
| P1 | Critical apps (Home Assistant) | 1 hour | 24 h (daily Velero) | ? | ? | never |
| P2 | Monitoring (Prometheus/Grafana) | 4 hours | 24 h | ? | ? | never |
| P3 | Media services (Plex) | 24 hours | 24 h | ? | ? | never |
| P3 | Postgres (CNPG) | 1 hour | 5 min (continuous WAL via Barman) | ? | ? | never |

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

# Recreate node via Terraform (CI-only — dispatch the proxmox workflow)
cd ~/code/infra/infra/terraform/proxmox/k8s-vms
terraform apply -target=proxmox_virtual_environment_vm.k8s_workers["<node-name>"]

# Re-add to cluster via Kubespray
cd ~/code/infra/infra/kubespray
./kubespray.sh scale.yml --limit=<node-name>
```

### 1.2 Control Plane Failure

**Symptoms:** kubectl commands fail, API unreachable.

**Recovery Steps:**

```bash
# 1. Access control plane node directly (any of cp1/cp2/cp3 — .50/.51/.52)
ssh ubuntu@10.10.201.50

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
- **Velero's PRIMARY repo is local Garage** (M137, since 2026-07-08) — an S3 server
  whose data lives on the NAS (`sequoia:/var/nfs/shared/VeleroBackup`) with metadata
  on a Ceph-RBD PVC. **Garage must be reconciled + Ready before Velero can list ANY
  post-07-08 backup** (see the Garage-dependency note in the recovery steps). Its
  bootstrap (layout + `velero` bucket + key import) is a runbook step on a fresh
  metadata volume — see `platform/kubernetes/garage/README.md`.
- The old **S3 Velero BSL is READ-ONLY** and holds only pre-07-08 restore points
  (30-day TTL) + a weekly `dr/` copy transitioned to **Glacier Deep Archive**
  (restoring from `dr/` needs a bulk Deep-Archive rehydration, ~12h — see
  `platform/kubernetes/velero-dr/README.md`).
- Access to kubespray inventory

**Recovery Procedure:**

```bash
# 1. Recreate VMs via Terraform (CI-only — dispatch the proxmox workflow)
cd ~/code/infra/infra/terraform/proxmox/k8s-vms
terraform apply

# 2. Wait for VMs to boot (5 minutes)
sleep 300

# 3. Deploy Kubernetes via Kubespray
cd ~/code/infra/infra/kubespray
./kubespray.sh cluster.yml

# 4. Velero is a Flux HelmRelease (clusters/wind/helm-releases/velero.yaml) — it
#    comes back with Flux in step 8, NOT a manual `helm install`. It uses IRSA
#    (useSecret=false; AssumeRoleWithWebIdentity via the projected SA token,
#    role wind-irsa-velero) — there is NO static AWS key. See
#    docs/runbooks/irsa-workload-identity.md.

# 5-6. (Velero is reconciled by Flux in step 8.) ⚠️ Velero's PRIMARY repo is local
#       Garage (M137) — it CANNOT list post-07-08 backups until Garage is Ready:
#         a. Garage deploys via Flux (platform/kubernetes/garage/). It needs the NAS
#            NFS share (sequoia:/var/nfs/shared/VeleroBackup) reachable + its Ceph-RBD
#            metadata PVC bound. On a FRESH metadata volume, re-run the one-time
#            bootstrap (layout assign/apply + `key import velero <GK…> <secret>` +
#            `bucket create/allow velero`) per platform/kubernetes/garage/README.md.
#         b. kubectl -n garage rollout status deploy/garage   # must be 1/1 Ready
#         c. Then: kubectl -n velero get backupstoragelocation garage  # → Available
#            and the `default` (S3) BSL is read-only (pre-07-08 restore points, 30d).
#       For a restore from the OFFSITE `dr/` copy (only if both Garage AND the S3
#       velero bucket's live objects are gone), first rehydrate the Deep-Archive
#       objects (bulk retrieval ~12h) then rclone them into a fresh Garage — see
#       platform/kubernetes/velero-dr/README.md.

# 7. Restore in order of priority (after step 8 has brought Velero up)
velero restore create restore-infra --from-backup infrastructure-daily-<latest>
velero restore create restore-critical --from-backup critical-apps-daily-<latest>
velero restore create restore-monitoring --from-backup monitoring-daily-<latest>

# 7a. PostgreSQL: if the Ceph RBD pgdata image survived the rebuild,
#     use the static-PV recovery pattern to ADOPT it instead of
#     letting CNPG run initdb on empty storage (which a vanilla Velero
#     restore of the PVC won't prevent). The manifests:
#       platform/kubernetes/cnpg/03-static-pv-recovery.yaml
#       platform/kubernetes/cnpg/04-pvc-pre-bind.yaml
#     are wired into the kustomization and ordered before 01-cluster.yaml.
#     See platform/kubernetes/cnpg/README.md §Disaster Recovery.

# 8. Deploy Flux to resume GitOps (no flux CLI on the hosts — apply the
#    committed bootstrap manifests, then point Flux at clusters/wind).
#    These are the gotk-components + gotk-sync that `flux bootstrap` commits.
kubectl apply -k clusters/wind/flux-system/
#    (gotk-sync.yaml already targets owner=sparked-diamond repo=infra
#     branch=main path=clusters/wind; reconcile to pull the rest)
kubectl annotate --overwrite -n flux-system gitrepository/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
kubectl annotate --overwrite -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"

# 9. Verify applications
kubectl get pods -A
kubectl get gitrepository,kustomization,helmrelease -A
```

---

## 2. Storage Recovery

### 2.1 Ceph OSD Failure

**Symptoms:** Ceph health warning, degraded PGs; K8s PVC ops (`rbd map`/create)
time out (`csi DeadlineExceeded`/`exit 108`) while the cluster looks fine.

Ceph is **external on the `pve` host** (not Rook/in-cluster — there is no
`rook-ceph` namespace or toolbox). Diagnose from the pve host over SSH:

```bash
ssh root@pve   # or the pve mgmt IP

# Check Ceph status + OSD tree
ceph -s
ceph osd tree

# Inspect a specific RBD image (stale watchers / blocklist after a node reboot)
rbd status k8s-ceph/<img>
ceph osd blocklist ls

# Restart a down OSD (PVE systemd; N = OSD id from `ceph osd tree`)
systemctl restart ceph-osd@<N>
```

If `ceph -s` is `HEALTH_OK` on pve but K8s rbd ops still time out, suspect the
**PVE host firewall** dropping the storage VLAN → mon/OSD (see CLAUDE.md §5 /
the `pve-ceph` security group).

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

### 2.3 Static-PV adoption (orphaned RBD image → new cluster)

**When to use this pattern:** the K8s cluster has been rebuilt (rebuild,
DR drill, migration), but the underlying Ceph RBD pool wasn't destroyed
— the images that backed your old PVs still exist. A vanilla Velero
restore re-creates the PVC and dynamically provisions a NEW empty RBD
image, throwing away the surviving data. To adopt the existing image
instead, pre-create a static PV that references it directly and a
pre-bound PVC pointing at that PV.

This is more reliable than Velero filesystem restore for large
datasets (no copy time, no risk of partial restore) and is the only
sane recovery for databases that wrote inside the volume after the
last filesystem backup window.

**The pattern (3 manifests, applied in order):**

1. **`PersistentVolume`** with `claimRef` to the future PVC and
   `volumeAttributes.staticVolume: "true"` (tells the ceph-csi driver
   not to try to provision; just mount).
2. **`PersistentVolumeClaim`** with `volumeName` pinned to that PV
   plus whatever app-specific labels/annotations are needed to
   convince the operator it's a real pre-existing PVC. CNPG needs
   `cnpg.io/pvcStatus: ready`; Helm chart-managed PVCs usually need
   `helm.sh/resource-policy: keep` on the chart.
3. **The workload** — operator / Deployment / StatefulSet — comes up
   *after* the PVC is Bound. The PVC stays put because the PV's
   `persistentVolumeReclaimPolicy: Retain` keeps it across delete
   churn.

**Worked example (CNPG postgres, shipping in-repo):**

```
platform/kubernetes/cnpg/03-static-pv-recovery.yaml  # PV → RBD image
platform/kubernetes/cnpg/04-pvc-pre-bind.yaml        # PVC pre-bound
platform/kubernetes/cnpg/01-cluster.yaml             # CNPG Cluster
```

The `kustomization.yaml` orders 03 and 04 before 01 so the CNPG
operator finds a `ready` PVC and adopts the existing pgdata instead
of running `bootstrap.initdb` over empty storage. See
[`platform/kubernetes/cnpg/README.md`](../../platform/kubernetes/cnpg/README.md)
§Disaster Recovery for full context.

**Finding the right RBD image name for a recovered workload:**

```bash
# 1. Connect to a Ceph mon (from any k8s node with toolbox, or from
#    the external Ceph cluster directly):
ceph osd pool ls
rbd ls -p k8s-ceph

# 2. Each image holds metadata about which PVC it backed. Match by
#    PVC name from the pre-rebuild cluster:
for img in $(rbd ls -p k8s-ceph); do
    echo "=== $img ==="
    rbd image-meta list "k8s-ceph/$img" 2>/dev/null | grep -E "csi.storage.k8s.io/(pvc/name|pvc/namespace)"
done

# 3. The matching image's name (e.g. csi-vol-0ef4fde9-...) is what
#    goes into volumeAttributes.imageName + volumeHandle in the PV.
```

**Apps where this pattern applies (anything with a ReadWriteOnce
ceph-rbd PVC that you can't afford to lose):**

- `home-automation/home-assistant` — config DB + integration state
- `plex/plex` — library metadata (re-scanning the media library from
  scratch is hours)
- `ollama/ollama` — model cache (`ollama-data-recovery` already
  uses this pattern; see the PVC's claimRef)
- `wikijs/wikijs` — content store
- Any postgres database via CNPG

**Apps where vanilla Velero restore is fine:**

- Anything stateless (Grafana settings live in K8s, dashboards via
  ConfigMap; Traefik is config-as-code; cert-manager re-issues from
  the cluster issuer; etc.)
- Anything with a fresh-bootstrap path that's faster than rebuilding
  the dataset (kopia repo data — Velero backup is the right copy)

**Operator-specific adoption gotchas:**

| Operator | What to set on the PVC | Why |
|---|---|---|
| CNPG (cnpg.io) | `annotations: cnpg.io/pvcStatus: ready` + `cnpg.io/instanceName` label | Operator scans for `ready` PVCs before deciding to initdb |
| stateful Helm charts | `annotations: helm.sh/resource-policy: keep` | Stops Helm from deleting the PVC on uninstall/upgrade |
| StatefulSets | None — STS reuses PVCs by name match | Just make sure the PVC name matches the STS volumeClaimTemplate naming convention (`<vct-name>-<sts-name>-<ordinal>`) |

---

## 3. DNS Recovery

### 3.1 Technitium Cluster Degraded

**Cluster nodes:** `technitium-0` (10.10.201.71) and `technitium-1` (10.10.201.72)
running as the K8s StatefulSet, plus `dns-fallback` (10.10.201.6) standalone VM
and the AWS **edge box** (`private-infra_edge`, hostname `vpn-aws`,
10.10.100.10 / EIP 44.240.60.80), which runs Technitium as an off-site replica.
Clients reach the in-cluster pair via MetalLB VIP 10.10.201.5. (M110, 2026-07-02:
the former separate `dns-aws` VM was destroyed and Technitium DNS folded onto the
edge box.)

```bash
# Check cluster status
curl -s "http://10.10.201.5:5380/api/admin/cluster/status?token=<token>"

# If K8s DNS pods are down, clients failover to dns-fallback
# UDM Pro DNS config: Primary=10.10.201.5, Secondary=10.10.201.6

# Restart K8s Technitium pods
kubectl rollout restart statefulset/technitium -n dns

# Check standalone nodes
curl -s "http://10.10.201.6:5380/api/dashboard/stats?token=<token>"
curl -s "http://10.10.100.10:5380/api/dashboard/stats?token=<token>"  # AWS edge box (vpn-aws)
```

### 3.2 Complete DNS Failure

**Immediate workaround:**
```bash
# On affected systems, use public DNS temporarily
echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf
```

**Recovery:**
```bash
# SSH to dns-fallback (standalone, always available; cert-only auth, M76)
ssh ubuntu@10.10.201.6

# Restart Technitium
sudo systemctl restart technitium

# Verify
curl -s "http://localhost:5380/api/dashboard/stats?token=<token>"
```

---

## 4. VPN Recovery

### Architecture Overview

The site-to-site VPN runs in high availability mode:
- **Primary:** K8s WireGuard pod (priority 150)
- **Backup:** vpn-fallback VM (priority 100)
- **VIP:** 10.10.201.20 (floating between K8s and vpn-fallback)

Failover is automatic via Keepalived VRRP.

### 4.1 Site-to-Site VPN Down

**Symptoms:** Cannot reach AWS resources (10.10.100.x) from local network.

```bash
# Check K8s WireGuard (primary)
kubectl get pods -n wireguard
kubectl exec -n wireguard deployment/wireguard -c wireguard -- wg show wg0

# Check VIP assignment
kubectl exec -n wireguard deployment/wireguard -c keepalived -- ip addr show | grep 10.10.201.20

# Check vpn-fallback (backup)
ansible vpn-fallback -m shell -a "wg show wg0; ip addr show | grep 10.10.201.20"

# Check AWS VPN gateway
ssh ubuntu@44.240.60.80 "sudo wg show"

# Restart K8s WireGuard
kubectl rollout restart deployment wireguard -n wireguard

# Restart AWS WireGuard
ssh ubuntu@44.240.60.80 "sudo systemctl restart wg-quick@wg0"

# Verify tunnel
ping 10.255.255.1  # AWS tunnel endpoint
```

### 4.2 K8s WireGuard Pod Failure

Automatic failover to vpn-fallback occurs within ~10-15 seconds.

```bash
# Verify vpn-fallback took over
ansible vpn-fallback -m shell -a "ip addr show | grep 10.10.201.20; wg show wg0"

# Force K8s pod restart
kubectl delete pod -n wireguard -l app=wireguard

# Or scale and restore
kubectl scale deployment wireguard -n wireguard --replicas=0
kubectl scale deployment wireguard -n wireguard --replicas=1
```

### 4.3 vpn-fallback VM Failure (Backup)

If K8s is primary, vpn-fallback failure has no immediate impact.

```bash
# Recreate vpn-fallback VM (CI-only — dispatch the proxmox workflow)
cd ~/code/infra/infra/terraform/proxmox/standalone-vms
terraform apply -target=proxmox_virtual_environment_vm.standalone["vpn-fallback"]

# Reconfigure WireGuard and Keepalived
cd ~/code/infra/infra/ansible
ansible-playbook -i inventory/wind/ playbooks/wireguard.yml --limit vpn-fallback
```

### 4.4 Complete Local Site Failure

If both K8s and vpn-fallback are down, restore K8s first (faster recovery):

```bash
# Restore K8s WireGuard (reconcile source git + the flux-system kustomization)
kubectl annotate --overwrite -n flux-system gitrepository/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
kubectl annotate --overwrite -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"

# Or apply manually
kubectl apply -k platform/kubernetes/wireguard/
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

# 3. Recreate VMs via Terraform (CI-only — dispatch the proxmox workflow)
cd ~/code/infra/infra/terraform/proxmox/k8s-vms
terraform apply
```

### 6.2 pve boot-disk total loss — restore /etc/pve + the Ceph MON (M130)

The daily `pve-config-backup.timer` (playbook `infra/ansible/playbooks/pve-config-backup.yml`)
tars `/etc/pve`, `/etc/ceph`, the Ceph MON store, bootstrap keyrings + an extracted
monmap → **`/mnt/pve/sequoia-backups/pve-config/`** on the NAS (sequoia, separate
hardware). Keeps the last 14; `PveConfigBackupStale` alerts if a run is missed.

```bash
# On the reinstalled pve host, with the NAS re-mounted:
LATEST=$(ls -1t /mnt/pve/sequoia-backups/pve-config/pve-config-*.tar.gz | head -1)
tar tzf "$LATEST"                               # inspect first
# /etc/pve is a FUSE mount (pmxcfs) — stop the service before restoring its backing store,
# then restore config + Ceph identity:
systemctl stop pve-cluster
tar xzf "$LATEST" -C / etc/ceph var/lib/ceph    # ceph.conf, keyrings, MON store
# restore /etc/pve contents into the pmxcfs backing DB per Proxmox docs (/var/lib/pve-cluster),
# or copy individual files back after pve-cluster restart:
systemctl start pve-cluster
cp -a /path/from/tarball/etc/pve/priv/* /etc/pve/priv/   # keyrings, tokens, TFA, root CA
# If the MON store is unrecoverable, rebuild the monitor from the OSDs + the saved monmap
# (ceph-mon --mkfs -i pve --monmap <extracted monmap> --keyring <ceph.mon.keyring>).
```

> ⚠️ The tarball contains `/etc/pve/priv` **secrets** (ceph keyrings, API tokens, the
> pve root CA). It's `chmod 600` and lives on the trusted NAS only.

**Offsite tier (3-2-1).** The `backups/pve-config-offsite` CronJob (daily 04:15,
`platform/kubernetes/velero-dr/04-pve-config-offsite.yaml`) mirrors the NAS `pve-config/`
dir → `s3://velero.wind.etherport.net/pve-config/` (IRSA, free ingress). If the **NAS
is also gone**, restore from S3 instead: `aws s3 cp s3://velero.wind.etherport.net/pve-config/<latest>.tar.gz .`
(standard storage — no Deep-Archive rehydration needed for this prefix) and follow the
same extract steps above. Staleness alert: `PveConfigOffsiteStale`.

---

## 7. Recovery Verification Checklist

After any recovery, verify:

- [ ] `kubectl get nodes` - All nodes Ready
- [ ] `kubectl get pods -A | grep -v Running` - No stuck pods
- [ ] `kubectl get gitrepository,kustomization,helmrelease -A` - All kustomizations synced
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

## 9. Postgres (CNPG) WAL-replay restore

Continuous WAL is shipped to S3 via Barman (CNPG operator handles it
automatically — see `platform/kubernetes/cnpg/01-cluster.yaml`
`backup` section). RPO of ~5min comes from `wal_compression` +
streaming, not nightly snapshots.

CNPG reaches S3 via **IRSA** (`inheritFromIAMRole: true`, role `wind-irsa-barman`
— no static key); the restore cluster needs the same projected-token/env wiring
as the live one (see `01-cluster.yaml`).

```bash
# 1. List available base backups + WAL files
kubectl exec -n postgres -it postgres-cluster-1 -c postgres -- \
  barman-cloud-backup-list s3://postgres-barman.wind.etherport.net/postgres-cluster

# 2. Create a new CNPG cluster from backup (point-in-time recovery)
cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres-cluster-restore
  namespace: postgres
spec:
  bootstrap:
    recovery:
      source: postgres-cluster
      recoveryTarget:
        targetTime: "2026-05-24 18:00:00.00000+00"  # adjust
  externalClusters:
    - name: postgres-cluster
      barmanObjectStore:
        destinationPath: s3://postgres-barman.wind.etherport.net
        s3Credentials:
          inheritFromIAMRole: true   # IRSA, not a static-key secret
EOF

# 3. After cluster is Ready, switch app connections to the new service:
kubectl -n postgres patch service postgres-cluster-rw \
  -p '{"spec":{"selector":{"cnpg.io/cluster":"postgres-cluster-restore"}}}'

# 4. Once verified, delete the old cluster + rename the new one.
```

---

## 10. Backup ownership matrix

What backs up what, where it lives, who restores it. Cross-reference
with `platform/kubernetes/monitoring/06-backup-alerts.yaml` for the
alerts that fire when any of these fail.

| Workload backed up | Backup tool | Location | Schedule | Restore proc |
|---|---|---|---|---|
| K8s resources + PVs | Velero (per-namespace schedules) | **Garage** (local S3-on-NAS) = PRIMARY (M137); S3 `velero.wind.etherport.net` = **read-only DR** (`dr/` mirror, weekly, Deep Archive) | daily | §1.3 above (Garage must be Ready first) |
| pve `/etc/pve` + Ceph MON store | `pve-config-backup.timer` (M130) + `pve-config-offsite` CronJob | NAS `/mnt/pve/sequoia-backups/pve-config/` + S3 `velero…/pve-config/` (3-2-1) | daily 03:30 / 04:15 PT | §6.2 above |
| Postgres data | CNPG Barman (continuous WAL + nightly base) | S3 `postgres-barman.wind.etherport.net` | continuous | §9 above |
| etcd | systemd timer on each CP node + Velero `kube-system-daily` ships /var/lib/etcd-snapshots | local + S3 | daily 02:00 PT | §1.2 above |
| UDM controller-db + UDM core-config + Protect core-config | `unifi-backup` CronJob | S3 `infra.wind.etherport.net/unifi/` | daily 04:00 PT | UDM UI restore (Settings → System → Restore) |
| NAS media + docs (7 shares) | `s3-sync` CronJob | per-share S3 buckets | daily 01:00 PT | `aws s3 sync s3://<bucket>/ /restore/` |
| Google Drive personal | `rclone gdrive-sync` CronJob | NFS share `/mnt/data/gdrive-mirror` | daily 00:00 PT | restore from NFS or re-sync from gdrive |
| UDM / UNVR / Sequoia wildcard cert | `unifi-cert-sync` CronJob | n/a (re-issued by cert-manager) | weekly Mon 04:00 | force re-run: `kubectl -n unifi-cert-sync create job --from=cronjob/unifi-cert-sync manual-$(date +%s)` |

---

## 11. RTO/RPO measurement drill

The Recovery Priority table at the top has TARGET values + a `?` in
the Measured column. To replace `?` with real numbers, schedule a
~2-hour quarterly drill:

**Setup:**
1. Pick a non-production-affecting recovery (e.g. restore a deleted
   Plex pod, or recover a deleted ConfigMap from Velero) so the
   drill doesn't risk live data.
2. Note start time T0.
3. Trigger the failure (`kubectl delete` the resource).
4. Note time T1 when the alert fires (RTO measurement starts here —
   real-world RTO is "time to detection + time to recovery").
5. Execute the relevant restore procedure from §1-§9.
6. Note T2 when service is verified back.

**Compute + record:**

- RTO = T2 - T1 (time from incident to service back)
- RPO = T0 - <timestamp of last successful backup before T0>

Update the table at the top of this file with the measured values
+ today's date in the Last drill column. Commit + push.

**Recommended drill rotation:**

| Quarter | Drill target |
|---|---|
| Q1 | Home Assistant pod (P1) — restore from Velero `critical-apps-daily` |
| Q2 | Postgres point-in-time recovery (P3 RPO test) — restore to alt cluster, verify a table row |
| Q3 | etcd snapshot restore on a non-active CP node (P1) |
| Q4 | Full Velero namespace recreation from scratch (Plex P3) |

Each drill produces 2 numbers + a refreshed `Last drill` date.
After a year of drills, the table has real numbers instead of
guesses.

---

## Related Documentation

- [PLATFORM-MANAGEMENT.md](PLATFORM-MANAGEMENT.md) - Overall platform operations
- [operations-guide.md](operations-guide.md) - Command quick reference
- [UPDATE-PROCEDURES.md](UPDATE-PROCEDURES.md) - Update procedures and schedules
