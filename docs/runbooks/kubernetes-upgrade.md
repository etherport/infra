# Kubernetes Upgrade Procedures

Step-by-step procedures for upgrading Kubernetes cluster components.

## Current Versions

| Component | Version | Upgrade Frequency |
|-----------|---------|-------------------|
| Kubernetes | v1.34.3 (2026-07-02) | Quarterly |
| containerd | 2.2.5 (2026-07-02, H45b CVE batch) | With K8s upgrade |
| Ubuntu | 24.04 LTS | Security: auto, Major: yearly |

## Upgrade Types

| Type | Risk | Downtime | Method |
|------|------|----------|--------|
| Patch (1.34.x → 1.34.y) | Low | None | Rolling update |
| Minor (1.34 → 1.35) | Medium | Minimal | Rolling update |
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

## ⚠️ `wind`-specific landmines checklist (READ BEFORE ANY kubespray RUN)

These are non-obvious to a generic K8s upgrade but WILL bite this cluster. Every
one is documented in `CLAUDE.md` §5; consolidated here as the pre/post gate.

**BEFORE the run:**
- [ ] **Run kubespray ONLY via `infra/kubespray/kubespray.sh`** — never a raw
      `cluster.yml`/`upgrade-cluster.yml`. The wrapper auto-runs `pre-flight.yml`
      afterward to restore `/opt/cni/bin` to `root:root`; a raw run chowns it to
      `kube` → Cilium `mount-cgroup` `Init:CrashLoopBackOff` on the next agent
      restart (LATENT — see [cilium-cni-dir-owner.md](cilium-cni-dir-owner.md)).
- [ ] **No HA API VIP.** `controlPlaneEndpoint` = the single cp1 `10.10.201.50`;
      workers use local `nginx-proxy`. Upgrade **cp1 LAST** (etcd leader + the API
      endpoint). Verify etcd quorum (`etcdctl endpoint health --cluster`,
      `/etc/etcd.env` has the certs) between each CP.
- [ ] **Drain-blockers:** single-instance CNPG pods with PDB `minAvailable=1`
      (e.g. `cue-db`) block a node drain and hang RBD unmount. `kubectl delete pod`
      the PDB-blocked ones after drain evicts the rest, before the node reboots.
- [ ] **Confirm the kubespray submodule supports the target `kube_version`** before
      bumping it (the pinned submodule caps the supported range).
- [ ] **containerd** is a kubespray binary (`/usr/local/bin/containerd`), NOT apt —
      it upgrades via `containerd_version` in inventory + the kubespray run, and is
      picked up per-node on the rolling restart. (H45b target: `2.2.5`.)

**AFTER the run (the IRSA/Multus landmines — verify EXPLICITLY, they fail silently):**
- [ ] **kube-apiserver `--service-account-issuer`** is STILL the OIDC bucket URL
      (`s3://wind-cluster-oidc-830881980142` endpoint) and `--api-audiences` is still
      pinned — a kubespray run can reset these from inventory. If the issuer changed,
      EVERY in-cluster IRSA token 401s. (M75; `apiserver-issuer-flip-api-audiences`.)
- [ ] **Restart Multus** after ANY issuer change: `kubectl -n kube-system rollout
      restart ds/kube-multus-ds-amd64` — it bakes its SA token once at pod start and
      never refreshes, so a stale `iss` → `multus … Unauthorized` → NO new pod
      schedules cluster-wide (the ~7h 2026-06-25 incident).
- [ ] **Cilium config not clobbered:** `policy-audit-mode` still OFF (enforce),
      WireGuard encryption still on, MetalLB BGP 8/8 (`cilium-dbg encrypt status`;
      `metallb_bgp_session_up`). A kubespray cilium tags run can revert these.
- [ ] **Per-kernel modules:** don't assume a module exists after a kernel bump — the
      `i6300esb` watchdog module is ABSENT from the node kernel (M91). Verify a module
      is present before relying on it; never add a `modprobe i6300esb` task.
- [ ] IRSA still assumes a role (spot-check one workload); velero/CNPG barman still archiving.

**H45b + M123 combined window (ready-to-run):** bump `kube_version: 1.34.2 → 1.34.3`
+ add `containerd_version: 2.2.5` in the inventory, then the rolling `kubespray.sh`
run (CP first per §2.3 but **cp1 last**, workers rolling per §2.4). EXECUTED 2026-07-02 — all 8 nodes
v1.34.3 + containerd 2.2.5, RECAP 0 failed/0 unreachable, all landmine checks passed
(issuer/audiences intact, multus 8/8, cilium enforce+WG+BGP 8/8, cni root:root).
Two run gotchas for next time: (1) kubespray v2.30 keeps the checksum DICTS in role
vars/ which BEAT inventory group_vars — override the SCALAR (e.g.
`containerd_archive_checksum`) from defaults/ instead; (2) run kubespray in a detached
tmux session (a harness-backgrounded run was killed mid-download); (3) a single-instance
CNPG pod (cue-db) WILL stall its node's drain on PDB — pre-arm a watch that deletes the
pod ~100s into that node's drain.
Two more from the 1.35 run (2026-07-02): (4) the PDB-blocked pod RESCHEDULES —
possibly onto the last un-upgraded node; when a later drain fails on it,
cordon-that-node-first + delete the pod + retry. (5) retrying a failed node with
`--limit` must NOT include already-upgraded control planes — kubespray re-runs
`kubeadm upgrade apply`, which fails post-upgrade ("no flags found in kubelet env
file") on an already-upgraded CP and leaves it CORDONED. `--limit <worker>` alone
works (drain delegation uses inventory vars, not gathered CP facts).

---

## 1. Patch Version Upgrade (e.g., 1.34.1 → 1.34.2)

Low risk, rolling update with zero downtime.

### 1.1 Update Kubespray Variables

```bash
# Check current version
grep kube_version infra/kubespray/inventory/group_vars/k8s_cluster/k8s-cluster.yml

# Update to new patch version
vim infra/kubespray/inventory/group_vars/k8s_cluster/k8s-cluster.yml
# Change: kube_version: 1.34.2
```

### 1.2 Run Upgrade Playbook

Always run kubespray via the `infra/kubespray/kubespray.sh` wrapper — it auto-runs
`pre-flight.yml` afterward to restore `/opt/cni/bin` ownership (raw `ansible-playbook`
breaks Cilium; see [cilium-cni-dir-owner.md](cilium-cni-dir-owner.md)).

```bash
# Run upgrade (control plane first, then workers)
infra/kubespray/kubespray.sh upgrade-cluster.yml

# Or upgrade one node at a time (safer)
infra/kubespray/kubespray.sh upgrade-cluster.yml --limit k8s-cp1
infra/kubespray/kubespray.sh upgrade-cluster.yml --limit k8s-w1

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
kubectl get --raw='/readyz?verbose'
```

---

## 2. Minor Version Upgrade (e.g., 1.34 → 1.35)

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
# Bump the kubespray submodule if a new minor needs a newer kubespray
git -C infra/kubespray/kubespray fetch && git -C infra/kubespray/kubespray checkout <tag>

# Update version in inventory
vim infra/kubespray/inventory/group_vars/k8s_cluster/k8s-cluster.yml
# Change: kube_version: 1.35.0
```

### 2.3 Upgrade Control Plane First

```bash
# Upgrade control plane only (via the wrapper — see §1.2)
infra/kubespray/kubespray.sh upgrade-cluster.yml --limit kube_control_plane

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

  # Run upgrade (via the wrapper)
  infra/kubespray/kubespray.sh upgrade-cluster.yml --limit $node

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
# Set in: infra/kubespray/inventory/group_vars/all/containerd.yml
```

### 3.2 Helm Chart Upgrades

The platform Helm charts (monitoring, loki, alloy, velero, metallb, …) are **Flux-managed
HelmReleases** under `clusters/wind/helm-releases/`. Do **not** run a direct
`helm upgrade` — it is out-of-band and gets reverted on the next Flux reconcile (and
there is no `helm`/`flux` CLI on the hosts). Bump the chart `version:` in git, commit/push,
then trigger a reconcile via annotation.

```bash
# Inspect what's installed (read-only)
kubectl get helmrelease -A

# Bump the chart version in the HelmRelease spec, e.g. monitoring:
#   clusters/wind/helm-releases/monitoring.yaml → spec.chart.spec.version
vim clusters/wind/helm-releases/monitoring.yaml
git commit -am "chore(deps): bump kube-prometheus-stack" && git push origin main

# Trigger Flux to pull + apply (no flux CLI on the hosts)
kubectl annotate --overwrite -n flux-system gitrepository/flux-system \
  reconcile.fluxcd.io/requestedAt="$(date +%s)"
kubectl annotate --overwrite -n flux-system kustomization/flux-system \
  reconcile.fluxcd.io/requestedAt="$(date +%s)"
kubectl annotate --overwrite -n flux-system helmrelease/monitoring \
  reconcile.fluxcd.io/requestedAt="$(date +%s)"

# Confirm the new revision applied
kubectl get helmrelease -n flux-system monitoring -o wide
```

### 3.3 Flux Upgrade

```bash
# Check current controller versions (no flux CLI on the hosts)
kubectl get pods -n flux-system -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'

# Upgrade Flux controllers GitOps-style: refresh the versioned install manifest in git
# (clusters/wind/flux-system/gotk-components.yaml), commit/push, and let Flux self-apply
# it on the next reconcile — a direct `kubectl apply` of the upstream manifest drifts
# from git and is reverted by the next reconcile.
curl -sL https://github.com/fluxcd/flux2/releases/download/v2.x.x/install.yaml \
  -o clusters/wind/flux-system/gotk-components.yaml
git commit -am "chore(flux): bump controllers to v2.x.x" && git push origin main

kubectl annotate --overwrite -n flux-system gitrepository/flux-system \
  reconcile.fluxcd.io/requestedAt="$(date +%s)"
kubectl annotate --overwrite -n flux-system kustomization/flux-system \
  reconcile.fluxcd.io/requestedAt="$(date +%s)"

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
ssh ubuntu@10.10.201.50

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
infra/kubespray/kubespray.sh upgrade-cluster.yml \
  --limit <failed-node> \
  --start-at-task="<task-name>"
```

### 5.2 API Server Unavailable

```bash
# SSH to control plane (any of cp1/cp2/cp3)
ssh ubuntu@10.10.201.50

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
ssh ubuntu@10.10.201.50

# Check etcd health
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
  endpoint health

# Check etcd logs (etcd runs as a host systemd service — etcd_deployment_type: host —
# so there is no etcd container; `crictl ps | grep etcd` returns nothing)
sudo journalctl -u etcd -f
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
